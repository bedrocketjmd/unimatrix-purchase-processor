module Unimatrix
  module PurchaseProcessor
    class PaymentsSubscriptionOrchestrator < TransactionOrchestrator
      def self.create_subscription( provider, attributes, request_attributes = nil )
        purchasing_realm                  = Realm.find_by( uuid: ENV[ 'MERCHANT_PURCHASING_REALM' ] ) || nil
        realm                             = Realm.find_by( id: attributes[ :realm_id ] ) || nil
        offer                             = Offer.find_by( id: attributes[ :offer_id ] )
        product                           = Product.find_by( id: attributes[ :product_id ].to_s )
        customer                          = Customer.find_by( id: attributes[ :customer_id ] )
        payments_subscription_attributes  = attributes.delete( :subscription_attributes ) || {}
        discount                          = 0.0
        coupon                            = nil
        coupon_code                       = attributes.delete( :coupon_code ) || nil
        metadata                          = attributes
        request_attributes                = request_attributes || nil
        provider                          = attributes[ :provider ]
        device_platform                   = attributes[ :device_platform ]

        orchestrator_response = nil

        unless !realm || !offer || !customer || !product
          # For Stripe
          merge_tokens( attributes )

          # If this is a subscription, allow multiple charges. If it's not, don't allow them.
          unless payments_subscription_attributes.blank? && existing_local_product( customer, product ).present?

            coupon, discount = apply_coupons( coupon_code, offer )

            if coupon.is_a?( OrchestratorError )
              orchestrator_response = coupon
            end

            payments_subscription_attributes = attributes_block( provider, realm, customer, offer, product, offer.price.to_f, discount, offer.currency,  device_platform )

            payments_subscription_attributes[ :coupon ] = coupon if coupon

            unless orchestrator_response.is_a?( OrchestratorError )
              if offer.price.to_f < 0.5
                # Charge amount too small
                orchestrator_response =  format_error( BadRequestError, 'The subscription amount must be greater than or equal to $0.50.' )
              else
                # Standard subscription
                adapter = "Unimatrix::PurchaseProcessor::#{ provider }Adapter".constantize.new
                adapter.refresh_api_key( realm ) if adapter.respond_to?( :refresh_api_key )

                if adapter.customer_valid?( customer ) && !orchestrator_response.is_a?( OrchestratorError )
                  tax_helper = TaxHelper.new( realm: purchasing_realm || realm, offer: offer, customer: customer, discount: discount )

                  payments_subscription_attributes[ :tax_percent ] = tax_helper.tax_percentage
                  payments_subscription_attributes[ :tax ] = tax_helper.total_tax

                  payments_subscription = adapter.new_subscription( customer, device_platform, offer )

                  if payments_subscription.valid?

                    if provider == "Stripe"
                      stripe_customer = StripeCustomer.create_or_confirm_existing_source( adapter, customer, attributes )

                      if stripe_customer && !stripe_customer.is_a?( Stripe::CardError )
                        stripe_coupon = coupon && discount ? StripeAdapter.generate_discount_coupon( discount, offer.currency ) : nil
                        subscriber = create_stripe_subscriber( stripe_customer, offer.stripe_plan_uuid, attributes[ :source ], tax_helper.tax_percentage, metadata.merge( attributes ).to_h, stripe_coupon )
                      else
                        subscriber = stripe_customer
                      end
                    elsif provider == "Paypal"
                      subscriber, redirect_url = create_paypal_subscriber( adapter, offer, tax_helper.total_tax, request_attributes, discount )
                    end

                    if !subscriber.is_a?( Stripe::CardError ) && adapter.subscription_successful?( subscriber ) && !subscriber.is_a?( OrchestratorError )
                      orchestrator_response = process_successful_subscription( subscriber, redirect_url, payments_subscription, payments_subscription_attributes )
                    elsif subscriber.is_a?( Stripe::CardError )
                      orchestrator_response = format_error( PaymentError, subscriber.json_body[ :error ][ :message ] )
                    else
                      orchestrator_response = format_error( PaymentError, 'There was an error processing your subscription. Please try again later.' )
                    end
                  else
                    orchestrator_response = format_error( BadRequestError, payments_subscription.errors.messages )
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
      # private methods

      def self.existing_local_product( customer, product )
        if Adapter.local_product_name == 'customer_product'
          CustomerProduct.where(
            customer_id: customer.id,
            product_id: product.id
          ).results.to_a.present?
        else
          false
        end
      end

      def self.create_stripe_subscriber( stripe_customer, plan, source, tax_percent, metadata, coupon = nil  )
        params = {
          plan: plan,
          source: source,
          tax_percent: tax_percent,
          metadata: metadata
        }

        if coupon
          params.merge!( coupon: coupon )
        end

        stripe_customer.subscriptions.create( params )
      end

      def self.create_paypal_subscriber( adapter, offer, total_tax, request_attributes, discount )
        payments_subscription_attributes = {
          offer: offer,
          tax: total_tax,
          discount: discount
        }

        subscriber = adapter.create_agreement(
          payments_subscription_attributes, request_attributes
        )

        if subscriber.create
          redirect_url = subscriber.links.find{ | v | v.rel == "approval_url" }.href

          [ subscriber, redirect_url ]
        else
          format_error( PaymentError, 'There was an error processing your subscription. Please try again later.' )
        end
      end

      def self.create_initial_free_transaction( attributes, payments_subscription )
        adapter = FreeAdapter.new

        transaction_attributes = {
          payments_subscription_id:   payments_subscription.id,
          payments_subscription_uuid: payments_subscription.uuid,
          customer_id:                payments_subscription.customer_id,
          customer_uuid:              payments_subscription.customer_uuid,
          product_id:                 payments_subscription.offer.product_id,
          product_uuid:               payments_subscription.offer.product_uuid,
          offer_id:                   payments_subscription.offer_id,
          offer_uuid:                 payments_subscription.offer_uuid,
          currency:                   payments_subscription.offer.currency,
          realm_uuid:                 attributes[ :realm ].uuid,
          coupon_id:                  attributes[ :coupon ].id,
          coupon_uuid:                attributes[ :coupon ].uuid,
          discount:                   attributes[ :discount ],
          subtotal:                   attributes[ :subtotal ],
          device_platform:            attributes[ :device_platform ],
          state:                      'pending'
        }

        transaction = adapter.new_purchase_transaction( transaction_attributes )

        if transaction.save
          transaction
        end
      end

      def self.process_successful_subscription( subscriber, redirect_url, payments_subscription, payments_subscription_attributes )
        if redirect_url
          payments_subscription.update( provider_id: subscriber.token )

          if payments_subscription_attributes[ :discount ].to_f == payments_subscription_attributes[ :offer ].price.to_f
            create_initial_free_transaction( payments_subscription_attributes, payments_subscription )
          end

          OrchestratorRedirect.new( payments_subscription, redirect_url )
        else
          payments_subscription.update( provider_id: subscriber.id )

          if payments_subscription_attributes[ :discount ].to_f == payments_subscription_attributes[ :offer ].price.to_f
            create_initial_free_transaction( payments_subscription_attributes, payments_subscription )
          end

          complete_subscription( payments_subscription, payments_subscription_attributes.merge( provider_id: subscriber.id ) )
          OrchestratorSuccess.new( payments_subscription )
        end
      end

      def self.complete_subscription( subscriber, attributes )
        local_product = nil
        if Adapter.local_product_name == 'realm_product'
          realm = find_or_create_realm( attributes[ :realm ], attributes[ :account_name ] )
          local_product = update_realm_product( subscriber, realm, attributes )
        else
          local_product = update_customer_product( subscriber, attributes )
        end

        if subscriber
          update_subscriber( subscriber, attributes, local_product )
          if subscriber.valid?
            PaymentsSubscriptionMailer.payments_subscription_confirmation(
              subscriber,
              'Thank you for your subscription!'
            ).deliver_now
          else
            BadRequestError.new(
              'Your order could not be saved'
            )
          end
        end
      end

      def self.update_customer_product( subscriber, attributes )
        customer_product_attributes = attributes.slice( :provider, :realm, :customer, :offer, :product )
        period_attributes = { expires_at: nil }
        offer = customer_product_attributes[ :offer ]
        period_attributes = { expires_at: ( Time.now.utc + 1.send( offer.period ) ) }
        customer_product = CustomerProduct.new( customer_product_attributes )
        customer_product.assign_attributes( customer_product_attributes.merge( period_attributes ) )

        customer_product_attributes.each do | key, value |
          customer_product.changed_attributes[ key ] = value
        end

        if customer_product.save
          customer_product
        end
      end

      def self.update_subscriber( subscriber, attributes, local_product )
        if subscriber.provider_id.nil?
          subscriber.provider_id = attributes[ :provider_id ]
        end

        if Adapter.local_product_name == 'customer_product'
          subscriber.attributes.merge!(
            :customer_product_uuid => local_product.uuid,
            :customer_product_id => local_product.id
          )
        else
          subscriber.update( "#{ Adapter.local_product_name }_id": local_product.id )
        end

        unless subscriber.state == 'active'
          subscriber.state = 'active'
        end

        update_initial_transaction( subscriber, local_product )

        if subscriber.valid?
          subscriber.save
        end

        subscriber
      end

      def self.update_initial_transaction( subscriber, local_product )
        transaction = Transaction.find_by( payments_subscription_uuid: subscriber.uuid, state: 'pending' )

        if transaction
          if Adapter.local_product_name == 'customer_product'
            transaction.customer_product_uuid = local_product.uuid
            transaction.customer_product_id = local_product.id
          else
            transaction.update( "#{ Adapter.local_product_name }_id": local_product.id )
          end

          transaction.state = 'complete'
          transaction.save
        end
      end

      def self.find_or_create_realm( realm, account_name )
        unless realm
          realm = Realm.create( account_name: account_name )
        end
        realm
      end

      def self.update_realm_product( subscriber, realm, attributes )
        realm_product_attributes = attributes.slice( :provider, :offer ).merge( { realm: realm, payments_subscription_id: subscriber.id } )
        period_attributes = { expires_at: nil }
        offer = realm_product_attributes.delete( :offer )
        period_attributes = { expires_at: ( Time.now.utc + 1.send( offer.period ) ) }
        realm_product = RealmProduct.find_or_initialize_by( realm_product_attributes )
        realm_product.assign_attributes( realm_product_attributes.merge( period_attributes ) )

        if realm_product.save
          realm_product
        end

        if subscriber.realm_product.nil?
          subscriber.realm_product = realm_product
        end

        if subscriber.save
          subscriber
        end
      end

      private_class_method :existing_local_product, :create_stripe_subscriber,
        :create_paypal_subscriber, :process_successful_subscription,
        :update_customer_product, :update_subscriber
    end
  end
end
