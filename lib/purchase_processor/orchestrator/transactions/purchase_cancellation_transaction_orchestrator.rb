module Unimatrix
  module PurchaseProcessor
    class PurchaseCancellationTransactionOrchestrator < TransactionOrchestrator
      def self.create_transaction( provider, attributes, request_attributes = nil )
        orchestrator_response = nil

        if attributes[ :realm_id ].present? && attributes[ :customer_product_id ].present? && attributes[ :customer_id ].present?
          realm = Realm.find_by( id: attributes[ :realm_id ] )
          customer_product = CustomerProduct.find_by( id: attributes[ :customer_product_id ] )

          if customer_product.present? && customer_product.customer_id.to_i == attributes[ :customer_id ].to_i
            if attributes[ :payments_subscription_id ].present?
              at_period_end = attributes[ :at_period_end ]

              if !at_period_end.nil? && ( at_period_end == true || at_period_end == false )
                customer = Customer.find( attributes[:customer_id] ) rescue nil

                if customer.present?
                  adapter = "Unimatrix::PurchaseProcessor::#{ provider }Adapter".constantize.new
                  adapter.refresh_api_key( realm ) if adapter.respond_to?( :refresh_api_key )

                  create_canceled_transaction( adapter, customer, attributes, at_period_end, customer_product )
                else
                  # could not find customer with that id
                  orchestrator_response = format_error( NotFoundError, 'A customer could not be found with the given id.' )
                end
              else
                orchestrator_response = format_error( MalformedParameterError, 'Missing or invalid required parameter at_period_end.' )
              end
            else
              # payment type must be subscription to cancel
              orchestrator_response = format_error( MalformedParameterError, 'The offer must be a reoccuring subscription in order to cancel it.' )
            end
          else
            orchestrator_response = format_error( MalformedParameterError, 'A customer product could not be found or is not related to the customer.')
          end
        else
          # render missing parameter error
          orchestrator_response = format_error( MissingParameterError, 'Missing required parameters: realm_id, customer_product_id, and customer_id.' )
        end
        return orchestrator_response
      end

      def self.create_canceled_transaction( adapter, customer, attributes, at_period_end, customer_product )
        begin
          if adapter.customer_valid?( customer )
            payments_subscription = PaymentsSubscription.find(
              attributes[ :payments_subscription_id ]
            )

            subscription = Stripe::Subscription.retrieve(
              payments_subscription.provider_id
            )

            if subscription.present?
              transaction = StripePurchaseCancellationTransaction.new( attributes )

              if transaction.valid?
                # pass true into method to cancel subscription
                payments_subscription.pause_subscription( true )
                transaction.save

                TransactionMailer.payment_error(
                  transaction,
                  "There was an error processing your transactions"
                ).deliver_now
              end

              orchestrator_response = OrchestratorSuccess.new( transaction )
            else
              # stripe subscription not found
              orchestrator_response = format_error( NotFoundError, 'A stripe subscription could not be found with the given provider_id.' )
            end
          else
            # cannot find stripe customer
            orchestrator_response = format_error( NotFoundError, 'A stripe customer could not be found with the given stripe_customer_uuid.' )
          end
        rescue Stripe::StripeError => error
          orchestrator_response = format_error( BadRequestError, "#{ error.message }" )
        end
      end
    end
  end
end
