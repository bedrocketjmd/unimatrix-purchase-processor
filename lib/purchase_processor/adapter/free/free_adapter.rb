module Unimatrix
  module PurchaseProcessor
    class FreeAdapter < Adapter
      include CurrencyHelper

      def new_purchase_transaction( attributes )
        transaction_attributes = attributes.merge(
          provider:           'Free',
          total:              0.0,
          total_usd:          0.0,
          total_revenue_usd:  0.0,
          total_revenue:      0.0,
          tax_percent:        0.0,
          tax:                0.0,
          tax_usd:            0.0,
          processing_fee:     0.0,
          processing_fee_usd: 0.0
        )

        transaction_attributes = FreeAdapter.approximate_missing_values( transaction_attributes )

        FreePurchaseTransaction.new( transaction_attributes )
      end

      def new_refund_transaction( reference_transaction, refund_attributes )
        existing_free_refund = FreeRefundTransaction.find_by( transaction_id: refund_attributes[ :transaction_id ] )

        if existing_free_refund.present?
          refund_attributes[ :provider_error ] = 'This purchase has already been refunded.'
        end

        FreeRefundTransaction.new( refund_attributes )
      end

      def self.approximate_missing_values( transaction_attributes )
        if transaction_attributes[ :currency ].present?
          if transaction_attributes[ :currency ] == 'USD'
            transaction_attributes.merge!(
              discount_usd: transaction_attributes[ :discount ],
              subtotal_usd: transaction_attributes[ :subtotal ],
            )
          else
            transaction_attributes[ :discount_usd ] = exchange_to_usd( transaction_attributes[ :discount ], transaction_attributes[ :currency ] )
            transaction_attributes[ :subtotal_usd ] = exchange_to_usd( transaction_attributes[ :subtotal ], transaction_attributes[ :currency ] )
          end
        end

        return transaction_attributes
      end
    end
  end
end
