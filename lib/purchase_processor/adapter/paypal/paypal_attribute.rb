module Unimatrix
  module PurchaseProcessor
    class PaypalAttribute < Adapter
      include PayPal::SDK::REST
      include PayPal::SDK::Core::Logging

      include CurrencyHelper::ClassMethods

      def attributes_from_webhook( event )
        object = event.resource

        object_name = event.resource_type.downcase

        payments_subscription = PaymentsSubscription.where( provider_id: object[ 'billing_agreement_id' ] ).first

        attributes = {}

        attributes = attributes_from_metadata( event, payments_subscription )

        attributes[ :provider_id ] = object[ "id" ]

        attributes[ :payments_subscription_id ] = payments_subscription.id

        attributes[ :customer_product_id ] = payments_subscription.customer_product.id

        if [ 'sale', 'agreement', 'dispute' ].include? object_name
          attributes = PaypalAdapter.send( "attributes_from_#{ object_name }", object ).merge( attributes )
        end

        PaypalAdapter.approximate_missing_purchase_values( attributes )
      end

      def attributes_from_metadata( event, payments_subscription )
        transaction_attributes = transaction_information_from_webhook( event.resource[ 'amount' ], payments_subscription )

        attributes = {
          realm_id: payments_subscription.customer_product.realm_id,
          offer_id: payments_subscription.customer_product.offer_id,
          product_id: payments_subscription.customer_product.product_id,
          customer_id: payments_subscription.customer_product.customer_id,
          device_platform: payments_subscription.device_platform,
          provider: "Paypal",
        }

        attributes.merge!( transaction_attributes )
      end

      def transaction_information_from_webhook( amount, payments_subscription )
         total = amount[ 'total' ].to_f

         paypal_subscription = payments_subscription.retrieve_subscription

         payment = paypal_subscription.plan.payment_definitions.select { | payment | payment.type == "REGULAR" }.first

         subtotal = payment.amount.value.to_f

         tax = payment.charge_models.select { | charge | charge.type == "TAX" }.first.amount.value.to_f

         attributes = {
           subtotal: subtotal,
           subtotal_usd: exchange_to_usd( subtotal, payments_subscription.customer_product.offer.currency ),
           tax: tax,
           total: total,
           total_usd: exchange_to_usd( total, amount[ 'currency' ] )
         }
       end

      def attributes_from_charge( object )
        if object.try( :plan )
          payment = object.plan.payment_definitions.first

          token = object.token

          attributes = {
            currency: payment.amount.currency,
            provider_id: token,
            total: payment.amount.value.to_f
          }
        else
          transaction_amount = object.transactions.first.amount

          attributes = {
            currency:            transaction_amount.currency,
            provider_id:         object.id,
            total:               transaction_amount.total.to_f
          }
        end

        attributes
      end

      def approximate_missing_purchase_values( attributes )
        if attributes[ :currency ].present?
          # Discount must be recalculated to account for any rounding
          # that may have been done by the provider.
          attributes[ :discount ] = attributes[ :subtotal ] -
                                    attributes[ :total ] +
                                    attributes[ :tax ]

          revenue =                 attributes[ :subtotal ] -
                                    attributes[ :discount ] +
                                    attributes[ :processing_fee ]

          attributes[ :subtotal_usd ] =      exchange_to_usd( attributes[ :subtotal ], attributes[ :currency ] )
          attributes[ :discount_usd ] =      exchange_to_usd( attributes[ :discount ], attributes[ :currency ] )
          attributes[ :tax_usd ] =           exchange_to_usd( attributes[ :tax ],      attributes[ :currency ] )
          attributes[ :total_usd ] =         exchange_to_usd( attributes[ :total ],    attributes[ :currency ] )
          attributes[ :total_revenue ] =     revenue
          attributes[ :total_revenue_usd ] = exchange_to_usd( revenue, attributes[ :currency ] )
        end

        attributes
      end

      def attributes_from_sale( object )
        attributes = {
          currency:       object[ "amount" ][ "currency" ],
          provider_id:    object[ "id" ],
          processing_fee: object[ "transaction_fee" ][ "value" ].to_f * -1,
        }
      end

      def attributes_from_dispute( object )
        begin
          attributes = {
            subtotal:         object[ "amount" ][  "total" ],
            response_code:    object[ "state" ],
            response_message: "Disputed Paypal Payment id:#{ object[ 'id' ] }"
          }

          attributes
        rescue
          {}
        end
      end
    end
  end
end
