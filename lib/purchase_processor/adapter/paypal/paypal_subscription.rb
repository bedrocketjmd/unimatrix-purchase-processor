module Unimatrix
  module PurchaseProcessor
    class PaypalSubscription < Adapter
      include PayPal::SDK::REST
      include PayPal::SDK::Core::Logging
      include CurrencyHelper

      def pause_subscription( agreement )
        unless agreement.state == "Suspended"
          agreement.suspend( note: "#{ agreement.id } paused." )
        else
          return "Subscription #{ agreement.id } already suspended"
        end
      end

      def resume_subscription( agreement )
        if agreement.state == "Suspended"
          agreement.re_activate( note: "Re-activated suscription #{ agreement.id }" )
        else
          "Subscription is #{ agreement.state }"
        end
      end

      def new_subscription( customer, device_platform, offer )
        PaymentsSubscription.new( customer: customer, provider: 'Paypal', device_platform: device_platform, offer: offer, state: 'inactive' )
      end

      def billing_agreement_from_event( event )
        object = event.resource

        result = Agreement.find( object[ "billing_agreement_id" ] )
      end

      def create_plan( offer, request )
        dealer_url = URI.parse( request.url )
        dealer_url = URI.join( dealer_url, '/' )

        offer_description =
          if offer.description.empty?
            "AS Roma Video"
          else
           offer.description.truncate( 22 )
          end

        plan = Plan.new(
          {
            name: offer.name,
            description: offer_description,
            type: offer.ends_at.nil? ? "INFINITE" : "FIXED",
            payment_definitions: define_plan_payments( offer ),
            merchant_preferences: {
              setup_fee: {
                currency: offer.currency,
                value: 0
              },
              cancel_url: dealer_url,
              return_url: dealer_url,
              max_fail_attempts: 1,
              auto_bill_amount: "YES",
              initial_fail_amount_action: "CANCEL"
            }
          }
        )

        if plan.create
          plan_update = {
            op: "replace",
            path: "/",
            value: {
              state: "ACTIVE"
            }
          }

          if plan.update( plan_update )
            plan
          else
            #this means we couldn't activate the plans
            return ErrorHash.convert( plan.error )
          end
        else
          #this means we couldn't create the plan
          return ErrorHash.convert( plan.error )
        end
      end

      def calculate_charge_cycle( offer )
        if offer.ends_at.present?
          cycles = {
            "year" => 1,
            "month" => 12,
            "week" => 365
          }
          charge_cycle = cycles[ offer.period ] || 0
        else
          charge_cycle = 0
        end

        charge_cycle
      end

      def calculate_trial_period( trial_period )
        cycle_attributes = {}
        if [ '1 day', '1 week', '1 month'].include? trial_period
          cycle_attributes[ :cycles ] = 1
          cycle_attributes[ :frequency ] = trial_period.split(" ").last.upcase
        else
          cycle_attributes[ :cycles ] = trial_period.split(" ").first.to_i
          cycle_attributes[ :frequency ] = "DAY"
        end
        cycle_attributes
      end

      def define_plan_payments( offer )
        payment_definitions = []

        charge_cycle = calculate_charge_cycle( offer )
        plan_uuid = SecureRandom.hex

        regular_payment =
          {
            name: "#{ offer.code_name }-#{ plan_uuid }",
            type: "REGULAR",
            frequency_interval: 1,
            frequency: offer.period,
            cycles: charge_cycle,
            amount: {
              currency: offer.currency,
              value: offer.price.to_i
            },
            charge_models: [
              {
                type: "TAX",
                amount: {
                  value: "0.00",
                  currency: offer.currency
                }
              }
            ]
          }

        if offer.trial_period.nil?
          payment_definitions.push( regular_payment )
        else
          trial_period_cycles = calculate_trial_period( offer.trial_period )

          trial_payment = {
            name: "#{ offer.code_name }-#{ plan_uuid }-trial",
            type: "TRIAL",
            frequency_interval: 1,
            frequency: trial_period_cycles[ :frequency ],
            cycles: 1,
            amount: {
              currency: offer.currency,
              value: "0.00"
            },
            charge_models: [
              {
                type: "TAX",
                amount: {
                  value: "0.00",
                  currency: offer.currency
                }
              }
            ]
          }

          payment_definitions.push( trial_payment, regular_payment )
        end
        payment_definitions
      end

      def create_agreement( payments_subscription_attributes, request_attributes )
        tax = payments_subscription_attributes.delete( :tax ) || nil
        offer = payments_subscription_attributes[ :offer ]

        dealer_url = URI.parse( request_attributes[ :url ] )
        dealer_url = URI.join( dealer_url, '/' )

        referrer_url = URI.parse( request_attributes[ :referer ] )
        referrer_url = URI.join( referrer_url, '/' )

        plan = Plan.find( offer.paypal_plan_uuid )

        payment_definitions = plan.payment_definitions.find { | v | v.type == "REGULAR" }

        charge_id =  payment_definitions.charge_models.find { | v | v.type == "TAX" }.id

        if payments_subscription_attributes[ :discount ]
          agreement_start_date = ( Time.now + 1.send( payment_definitions.frequency.downcase ) + 1.minutes ).iso8601
          setup_fee = offer.price.to_f - payments_subscription_attributes[ :discount ]
        else
          agreement_start_date = ( Time.now + 1.minutes ).iso8601
          setup_fee = 0
        end

        @agreement = Agreement.new(
          {
            name: offer.name,
            description: offer.description.truncate( 22 ) || "None",
            start_date: agreement_start_date,
            plan: {
              id: offer.paypal_plan_uuid
            },
            payer: {
              payment_method: "paypal"
            },
            override_charge_models: [
              {
                charge_id: charge_id,
                amount: {
                  value: tax,
                  currency: offer.currency
                }
              }
            ],
            override_merchant_preferences: {
              setup_fee: {
                value: setup_fee,
                currency: offer.currency
              },
              return_url: "#{ dealer_url }paypal/payments_subscriptions/execute?redirect_uri=#{ CGI.escape( referrer_url.to_s ) }",
              cancel_url: "#{ dealer_url }paypal/payments_subscriptions/cancel?redirect_uri=#{ CGI.escape( referrer_url.to_s ) }"
            }
          }
        )
        @agreement
      end

      def execute_agreement( token )
        agreement = Agreement.new()
        agreement.token = token

        if agreement.execute
          agreement
        else
          logger.error agreement.error.inspect
        end
      end

      def find_webhook_event( resource_id )
        raise ArgumentError.new( "webhook_event_id required" ) if resource_id.to_s.strip.empty?
        path = "v1/notifications/webhooks-events/#{ resource_id }"
        WebhookEvent.new( WebhookEvent.api.get( path ) )
      end

      def pay_delinquent_subscription( payments_subscription )
        provider_subscription = payments_subscription.retrieve_subscription

        balance = provider_subscription.agreement_details.outstanding_balance

        begin
          provider_subscription.bill_balance(
              note: "Attempted repayment: #{ Time.now }",
              amount: {
                value: balance.value.to_f,
                currency: balance.currency
              }
            )
        rescue => err
          payments_subscription
        end

        new_balance = payments_subscription.retrieve_subscription.agreement_details.outstanding_balance.value.to_f

        if new_balance && new_balance.zero?
          payments_subscription.resume_subscription
          relation = Adapter.local_product( payments_subscription )
          relation.update( expires_at: provider_subscription.agreement_details.next_billing_date )
        end
        payments_subscription
      end

      def zero_balance?( provider_subscription )
        provider_subscription.agreement_details.outstanding_balance.value.to_f.zero?
      end
    end
  end
end
