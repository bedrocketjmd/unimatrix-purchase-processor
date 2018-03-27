module Unimatrix
  module PurchaseProcessor
    class PurchaseTransactionOrchestrator < TransactionOrchestrator
      def self.create_transaction( provider, attributes, request_attributes = nil )
        purchasing_realm         = Realm.find_by( uuid: ENV[ 'MERCHANT_PURCHASING_REALM' ] ) || nil
        realm                    = Realm.find_by( id: attributes[ :realm_id ].to_s ) || nil
        offer                    = Offer.find_by( id: attributes[ :offer_id ].to_s )
        product                  = Product.find_by( id: attributes[ :product_id ].to_s )
        customer                 = Customer.find_by( id: attributes[ :customer_id ].to_s )
        subscription_attributes  = attributes.delete( :subscription_attributes ) || {}
        discount                 = 0.0
        coupon                   = nil
        coupon_code              = attributes.delete( :coupon_code ) || nil
        metadata                 = attributes
        request_attributes       = request_attributes || nil
        provider                 = attributes[ :provider ]
        device_platform          = attributes[ :device_platform ]

        orchestrator_response = nil

        unless !realm || !offer || !customer || !product
          # For Stripe
          merge_tokens( attributes )

          unless subscription_attributes.blank? && existing_local_product( customer, product ).present?
            # If this is a subscription, allow multiple charges. If it's not, don't allow them.
            coupon, discount = apply_coupons( coupon_code, offer )

            if coupon.is_a?( OrchestratorError )
              orchestrator_response = coupon
            end

            transaction_attributes = attributes_block( provider, realm, customer, offer, product, offer.price, discount, offer.currency,  device_platform )

            transaction_attributes[ :coupon ] = coupon if coupon

            unless orchestrator_response.is_a?( OrchestratorError )
              if offer.price.to_f == 0.0 || ( coupon.present? && offer.price.to_f - discount.to_f <= 0 )
                # Free offer or 100% discount

                adapter = FreeAdapter.new

                transaction = adapter.new_purchase_transaction( transaction_attributes )

                complete_transaction( transaction, transaction_attributes )

                if transaction.persisted?
                  orchestrator_response = OrchestratorSuccess.new( transaction )
                else
                  orchestrator_response = format_error( BadRequestError, transaction.errors.messages )
                end
              elsif offer.price.to_f < 0.5
                # Charge amount too small
                orchestrator_response = format_error( BadRequestError, 'The charge amount must be greater than or equal to $0.50.' )
              else
                # Standard charge
                adapter = "Unimatrix::PurchaseProcessor::#{ provider }Adapter".constantize.new
                adapter.refresh_api_key( realm ) if adapter.respond_to?( :refresh_api_key )

                if adapter.customer_valid?( customer ) && !orchestrator_response.is_a?( OrchestratorError )
                  tax_helper = TaxHelper.new( realm: purchasing_realm || realm, offer: offer, customer: customer, discount: discount )

                  transaction_attributes[ :tax_percent ] = tax_helper.tax_percentage
                  transaction_attributes[ :tax ] = tax_helper.total_tax

                  transaction_attributes = extract_attribute_ids( transaction_attributes )
                  transaction_attributes = set_monetary_values( transaction_attributes )

                  transaction = adapter.new_purchase_transaction( transaction_attributes )

                  if transaction.valid?
                    if provider == 'Stripe' && attributes[ :source_type ].present? && attributes[ :source_type ] == 'source'
                      StripeCustomer.create_or_confirm_existing_source( adapter, customer, attributes )
                    end

                    charge, redirect_url = adapter.create_charge(
                      customer:           customer,
                      amount:             ( ( offer.price.to_f - discount.to_f ) + tax_helper.total_tax ).to_f,
                      offer:              offer,
                      currency:           offer.currency,
                      metadata:           metadata.merge( attributes ),
                      request_attributes: request_attributes,
                      source_type:        attributes.delete( :source_type ) || nil,
                    )

                    if !charge.is_a?( Stripe::CardError ) && adapter.charge_successful?( charge )
                      orchestrator_response = process_successful_charge( charge, transaction, transaction_attributes, redirect_url )
                    elsif charge.is_a?( Stripe::CardError )
                      orchestrator_response = format_error( PaymentError, charge.json_body[ :error ][ :message ] )
                    else
                      orchestrator_response = format_error( PaymentError, 'There was an error charging your card. Please try again later.' )
                    end
                  else
                    orchestrator_response = format_error( BadRequestError, transaction.errors.messages )
                  end
                else
                  orchestrator_response = format_error( PaymentError, 'There was an error processing your payment and your card was not charged. Please try again later.' )
                end
              end
            else
              orchestrator_response
            end
          else
            orchestrator_response = format_error( BadRequestError, 'Customer already has access to this product.' )
          end
        else
          orchestrator_response = format_error( MissingParameterError, 'One or more of the required parameters is missing: realm_id, offer_id, customer_id, product_id.' )
        end

        orchestrator_response
      end

      #----------------------------------------------------------------------------

      def self.extract_attribute_ids( attributes )
        attributes[ :customer_id ] = attributes[ :customer ].id
        attributes[ :customer_uuid ] = attributes.delete( :customer ).uuid

        attributes[ :offer_id ] = attributes[ :offer ].id
        attributes[ :offer_uuid ] = attributes.delete( :offer ).uuid

        attributes[ :product_id ] = attributes[ :product ].id
        attributes[ :product_uuid ] = attributes.delete( :product ).uuid

        attributes[ :realm_uuid ] = attributes.delete( :realm ).uuid

        attributes
      end

      def self.existing_local_product( customer, product )
        if Adapter.local_product_name == 'customer_product'
          CustomerProduct.where(
            customer_id: customer.id,
            product_id: product.id
          ).results.to_a.length > 0
        else
          false
        end
      end

      def self.process_successful_charge( charge, transaction, transaction_attributes, redirect_url )
        if transaction.update_charge_attributes( charge )
          # If there is a redirect URL, complete_transaction will be called at a later time.
          if redirect_url
            OrchestratorRedirect.new( transaction, redirect_url )
          else
            # We still need to call this because the CustomerProduct is created in complete_transaction.
            complete_transaction( transaction, transaction_attributes )

            OrchestratorSuccess.new( transaction )
          end
        else
          # It would be bad if this error ever occurred because that would mean
          # a charge has been made but access was not granted.
          format_error( BadRequestError, 'There was an error saving your transaction. Please contact your administrator.' )
        end
      end

      def self.create_payments_subscription( transaction, attributes )
        payments_subscription_attributes = attributes.slice( :provider, :offer, :customer )
        payments_subscription = PaymentsSubscription.find_or_initialize_by( payments_subscription_attributes.merge( { device_platform: transaction.device_platform, provider_id: transaction.provider_id } ) )
        payments_subscription.save

        payments_subscription
      end

      def self.generate_realm( account_name=nil )
        realm = Realm.new

        realm.save

        realm
      end

      def self.create_realm_product( realm_product_attributes, period_attributes )
        offer = realm_product_attributes.delete( :offer )

        if offer.period.present?
          period_attributes = { expires_at: ( Time.now.utc + 1.send( offer.period ) ) }
        end

        realm_product = RealmProduct.find_or_initialize_by( realm_product_attributes )

        realm_product.assign_attributes( period_attributes )

        if realm_product.realm_id.nil?
          realm = generate_realm
          realm_product.realm = realm
        end

        if realm_product.save
          realm_product
        end
      end

      def self.create_customer_product( customer_product_attributes, period_attributes )
        offer = Offer.find_by( uuid: customer_product_attributes[ :offer_uuid ] )

        if offer.period.present?
          period_attributes = { expires_at: ( Time.now.utc + 1.send( offer.period ) ) }
        end

        customer_product = CustomerProduct.find_by( customer_product_attributes )

        if customer_product
          customer_product.assign_attributes( customer_product_attributes.merge( period_attributes ) )
        else
          customer_product = CustomerProduct.new( customer_product_attributes.merge( period_attributes ) )
        end

        if customer_product.save
          customer_product
        end
      end

      def self.complete_transaction( transaction, attributes )
        period_attributes = { expires_at: nil }

        if Adapter.local_product_name == 'realm_product'
          payments_subscription = create_payments_subscription( transaction, attributes )
          realm_product_attributes = { provider: attributes[ :provider ], payments_subscription_id: payments_subscription.id, offer: attributes[ :offer ] }
          local_product = create_realm_product( realm_product_attributes, period_attributes )
        else
          customer_product_attributes = attributes.slice( :provider, :realm_uuid, :customer_uuid, :offer_uuid, :product_uuid )
          local_product = create_customer_product( customer_product_attributes, period_attributes )
        end

        if transaction
          transaction.update( "#{ Adapter.local_product_name }_id": local_product.id )
          transaction.save

          if transaction.valid?
            local_product.save

            TransactionMailer.purchase_confirmation(
              transaction,
              'Thank you for your order!'
            ).deliver_now
          else
            BadRequestError.new(
              'Your order could not be saved'
            )
          end
        end

        return transaction
      end

      def self.set_monetary_values( attributes )
        monetary_types = [ 'float', 'integer' ]

        attributes.each do | key, value |
          if monetary_types.index( Transaction.repository.mappings.properties[ key.to_s ][ 'type' ] )
            type_index = monetary_types.index( Transaction.repository.mappings.properties[ key.to_s ][ 'type' ] )
            conversion_letter = monetary_types[ type_index ].split( '' ).first
            attributes[ key ] = value.send( "to_#{ conversion_letter }" )
          end
        end

        attributes
      end

      private_class_method :existing_local_product, :process_successful_charge
    end
  end
end
