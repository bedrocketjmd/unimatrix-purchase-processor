module Unimatrix
  module PurchaseProcessor
    class StripeRefund < Adapter
      def new_refund_transaction( reference_transaction, refund_attributes )
        if refund_attributes.present?
          charge_id =
            if reference_transaction.provider_id.present?
              reference_transaction.provider_id
            end

          begin
            refund = Stripe::Refund.create(
              charge: charge_id,
              amount: ( refund_attributes[ :total ].round( 2 ) * -100 ).to_i,
              metadata: {
                reference_transaction_id: reference_transaction.id
              }
            )

            if refund.status == 'succeeded'
              # Total needs to be reset to account for any rounding that Stripe may have done.
              # Totals for refunds are stored as negative numbers.
              exponent = StripeAdapter.exponent_from_currency( refund.currency )
              refund_attributes[ :total ] = StripeAdapter.format_stripe_money( refund.amount, exponent ) * -1

              balance_transaction = Stripe::BalanceTransaction.retrieve( refund.balance_transaction )

              refund_attributes.merge!( StripeAdapter.attributes_from_balance_transaction( balance_transaction ) )

              refund_attributes.merge!(
                StripeAdapter.approximate_missing_values( refund_attributes )
              )

              refund_attributes.merge!(
                transaction_id: reference_transaction.id,
                # refund id leads back to Stripe::Refund, which
                # contains id for refunded charge
                provider_id: refund.id
              )
            else
              refund_attributes[ :provider_error ] = "Error: #{ refund.error.inspect }"
            end
          rescue Stripe::InvalidRequestError => error
            refund_attributes[ :provider_error ] = error.message
          end
        end

        StripeRefundTransaction.new( refund_attributes )
      end
    end
  end
end
