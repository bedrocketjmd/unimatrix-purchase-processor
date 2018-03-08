class PurchaseTransactionOrchestrator < TransactionOrchestrator
  def self.create_transaction( provider, attributes, request_attributes = nil )
    realm                    = Realm.find_by( id: attributes[ :realm_id ] )
    offer                    = Offer.find_by( id: attributes[ :offer_id ] )
    product                  = Product.find_by( id: attributes[ :product_id ] )
    customer                 = Customer.find_by( id: attributes[ :customer_id ] )
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

      unless subscription_attributes.blank? && existing_customer_product( customer, product ).present?
        # If this is a subscription, allow multiple charges. If it's not, don't allow them.
        coupon, discount = apply_coupons( coupon_code, offer )

        if coupon.is_a?( OrchestratorError )
          orchestrator_response = coupon
        end

        transaction_attributes = attributes_block( provider, realm, customer, offer, product, offer.price, discount, offer.currency,  device_platform )

        transaction_attributes[ :coupon ] = coupon if coupon

        unless orchestrator_response.is_a?( OrchestratorError )
          if offer.price == 0.0 || ( coupon.present? && offer.price - discount <= 0 )
            # Free offer or 100% discount

            adapter = FreeAdapter.new

            transaction = adapter.new_purchase_transaction( transaction_attributes )

            complete_transaction( transaction, transaction_attributes )

            if transaction.persisted?
              orchestrator_response = OrchestratorSuccess.new( transaction )
            else
              orchestrator_response = format_error( BadRequestError, transaction.errors.messages )
            end
          elsif offer.price < 0.5
            # Charge amount too small
            orchestrator_response = format_error( BadRequestError, 'The charge amount must be greater than or equal to $0.50.' )
          else
            # Standard charge
            adapter = "Unimatrix::PurchaseProcessor::#{ provider }Adapter".constantize.new
            adapter.refresh_api_key( realm ) if adapter.respond_to?( :refresh_api_key )

            if adapter.customer_valid?( customer ) && !orchestrator_response.is_a?( OrchestratorError )
              # calculated_taxes = tax_helper( realm, offer, customer, discount )

              tax_helper = TaxHelper.new( realm: realm, offer: offer, customer: customer, discount: discount )

              transaction_attributes[ :tax_percent ] = tax_helper.tax_percentage
              transaction_attributes[ :tax ] = tax_helper.total_tax

              transaction = adapter.new_purchase_transaction( transaction_attributes )

              if transaction.valid?
                if provider == 'Stripe' && attributes[ :source_type ].present? && attributes[ :source_type ] == 'source'
                  StripeCustomer.create_or_confirm_existing_source( adapter, customer, attributes )
                end

                charge, redirect_url = adapter.create_charge(
                  customer:           customer,
                  amount:             ( ( offer.price - discount ) + tax_helper.total_tax ).to_f,
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

  def self.existing_customer_product( customer, product )
    CustomerProduct.where(
      customer_id: customer.id,
      product_id: product.id
    ).active
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

  def self.complete_transaction( transaction, attributes )
    customer_product_attributes = attributes.slice( :provider, :realm, :customer, :offer, :product )

    period_attributes = { expires_at: nil }

    offer = customer_product_attributes[ :offer ]

    if offer.period.present?
      period_attributes = { expires_at: ( Time.now.utc + 1.send( offer.period ) ) }
    end

    customer_product = CustomerProduct.find_or_initialize_by( customer_product_attributes )

    customer_product.assign_attributes( customer_product_attributes.merge( period_attributes ) )

    customer_product.save

    if transaction
      transaction.customer_product = customer_product
      transaction.save

      if transaction.valid?
        customer_product.successful_payments = 1
        customer_product.save

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

  private_class_method :existing_customer_product, :process_successful_charge
end
