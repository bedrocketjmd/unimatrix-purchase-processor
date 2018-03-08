class PaymentsSubscriptionOrchestrator < TransactionOrchestrator
  def self.create_subscription( provider, attributes, request_attributes = nil )
    realm                             = Realm.find_by( id: attributes[ :realm_id ] )
    offer                             = Offer.find_by( id: attributes[ :offer_id ] )
    product                           = Product.find_by( id: attributes[ :product_id ] )
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
      unless payments_subscription_attributes.blank? && existing_customer_product( customer, product ).present?

        coupon, discount = apply_coupons( coupon_code, offer )

        if coupon.is_a?( OrchestratorError )
          orchestrator_response = coupon
        end

        payments_subscription_attributes = attributes_block( provider, realm, customer, offer, product, offer.price, discount, offer.currency,  device_platform )

        payments_subscription_attributes[ :coupon ] = coupon if coupon

        unless orchestrator_response.is_a?( OrchestratorError )
          if offer.price < 0.5
            # Charge amount too small
            orchestrator_response =  format_error( BadRequestError, 'The subscription amount must be greater than or equal to $0.50.' )
          else
            # Standard subscription
            adapter = "Unimatrix::PurchaseProcessor::#{ provider }Adapter".constantize.new
            adapter.refresh_api_key( realm ) if adapter.respond_to?( :refresh_api_key )

            if adapter.customer_valid?( customer ) && !orchestrator_response.is_a?( OrchestratorError )
              # calculated_taxes = tax_helper( realm, offer, customer, 0.0 )

              tax_helper = TaxHelper.new( realm: realm, offer: offer, customer: customer, discount: discount )

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

  def self.existing_customer_product( customer, product )
    CustomerProduct.where(
      customer_id: customer.id,
      product_id: product.id
    ).active
  end

  def self.free_subscription( customer, device_platform, offer, payments_subscription, payments_subscription_attributes )
    # this isn't really being used now
    adapter = FreeAdapter.new

    payments_subscription = adapter.new_subscription( customer, device_platform, offer )

    complete_subscription( payments_subscription, payments_subscription_attributes )

    if payments_subscription.persisted?
      OrchestratorSuccess.new( payments_subscription )
    else
      format_error( BadRequestError, payments_subscription.errors.messages )
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

  def self.process_successful_subscription( subscriber, redirect_url, payments_subscription, payments_subscription_attributes )
    if redirect_url
      payments_subscription.update( provider_id: subscriber.token )
      OrchestratorRedirect.new( payments_subscription, redirect_url )
    else
      complete_subscription( payments_subscription, payments_subscription_attributes.merge( provider_id: subscriber.id ) )
      OrchestratorSuccess.new( payments_subscription )
    end
  end

  def self.complete_subscription( subscriber, attributes )
    customer_product = update_customer_product( subscriber, attributes )

    if subscriber
      update_subscriber( subscriber, attributes, customer_product )
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

    return subscriber
  end

  def self.update_customer_product( subscriber, attributes )
    customer_product_attributes = attributes.slice( :provider, :realm, :customer, :offer, :product )
    period_attributes = { expires_at: nil }
    offer = customer_product_attributes[ :offer ]
    period_attributes = { expires_at: ( Time.now.utc + 1.send( offer.period ) ) }
    customer_product = CustomerProduct.find_or_initialize_by( customer_product_attributes )
    customer_product.assign_attributes( customer_product_attributes.merge( period_attributes ) )
    if customer_product.save
      customer_product
    end
  end

  def self.update_subscriber( subscriber, attributes, customer_product )
    if subscriber.provider_id.nil?
      subscriber.provider_id = attributes[ :provider_id ]
    end
    subscriber.customer_product = customer_product
    subscriber.save
  end


  private_class_method :existing_customer_product, :free_subscription, :create_stripe_subscriber,
    :create_paypal_subscriber, :process_successful_subscription,
    :update_customer_product, :update_subscriber
end