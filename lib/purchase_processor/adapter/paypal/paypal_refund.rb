module Unimatrix
  module PurchaseProcessor
    class PaypalRefund < Adapter
      include PayPal::SDK::REST
      include PayPal::SDK::Core::Logging

      include CurrencyHelper::ClassMethods

      def new_refund_transaction( reference_transaction, refund_attributes )
        if refund_attributes.present?
          sale_id = reference_transaction.provider_id
          sale ||= Sale.find( sale_id ) if sale_id

          if sale.present?
            refund = sale.refund( {
              :amount => {
                :total => '%.2f' % ( refund_attributes[ :total ] * -1 ),
                :currency => reference_transaction.currency
              }
            } )

            if refund.success?
              # Total needs to be reset to account for any rounding that PayPal may have done.
              # Totals for refunds are stored as negative numbers.
              refund_attributes[ :total ] = refund.amount.total.to_f * -1

              refund_attributes.merge!(
                PaypalAdapter.approximate_missing_refund_values( reference_transaction, refund_attributes )
              )

              if refund_attributes[ :total ] == reference_transaction.total.to_f * -1
                # Full refund

                refund_attributes[ :processing_fee_usd ] = reference_transaction.processing_fee_usd.to_f * -1
              else
                # Partial refund

                # We have to calculate processing fee manually here because PayPal does not provide it
                # in their API response for refunds.
                # We have to start with _usd because, for partial refunds, PayPal retains $0.30 USD,
                # not original currency.
                # We then round to the exponent of the currency in use to try to guess what exact amount
                # PayPal is going to use. It's possible that this will be 1 cent off sometimes.
                currency_exponent = Money::Currency.new( refund_attributes[ :currency ] ).exponent.to_i
                fee_usd = refund_attributes[ :total_usd ] * 0.029 * -1
                refund_attributes[ :processing_fee_usd ] = fee_usd.round( currency_exponent )
              end

              if refund_attributes[ :currency ] == 'USD'
                usd_refund_attributes( refund_attributes )
              else
                international_refund_attributes( refund_attributes, reference_transaction )

                international_total_revenue( refund_attributes )
              end

              refund_attributes.merge!(
                transaction_id: reference_transaction.id,
                provider_id: refund.id,
              )
            else
              refund_attributes[ :provider_error ] = "Could not complete refund for sale #{ sale_id }. Error: #{ refund.error.inspect }."
            end
          else
            refund_attributes[ :provider_error ] = "Could not find a sale with id #{ sale_id }. Cannot refund."
          end
        end

        PaypalRefundTransaction.new( refund_attributes )
      end

      def usd_refund_attributes( refund_attributes )
        refund_attributes[ :processing_fee ] =    refund_attributes[ :processing_fee_usd ]
        # processing_fee is a positive number
        revenue = refund_attributes[ :subtotal ] -
                  refund_attributes[ :discount ] +
                  refund_attributes[ :processing_fee ]

        refund_attributes[ :total_revenue ] =     revenue
        refund_attributes[ :total_revenue_usd ] = revenue
      end

      def international_refund_attributes( refund_attributes, reference_transaction )
        # Processing fee is reversed because that's how it's returned from PayPal
        # Don't do ratio calculation unless necessary because it's less accurate
        if refund_attributes[ :total ] == reference_transaction.total.to_f * -1
          # Full refund
          refund_attributes[ :processing_fee ] =  reference_transaction.processing_fee.to_f * -1
        else
          # Partial refund
          refund_attributes[ :processing_fee ] =  exchange_by_ratio(
                                                    refund_attributes[ :processing_fee_usd ],
                                                    refund_attributes[ :total ],
                                                    refund_attributes[ :total_usd ]
                                                  )
        end
      end

      def international_total_revenue( refund_attributes )
        # processing_fee and processing_fee_usd are positive numbers
        refund_attributes[ :total_revenue ] =     refund_attributes[ :subtotal ] -
                                                  refund_attributes[ :discount ] +
                                                  refund_attributes[ :processing_fee ]

        refund_attributes[ :total_revenue_usd ] = refund_attributes[ :subtotal_usd ] -
                                                  refund_attributes[ :discount_usd ] +
                                                  refund_attributes[ :processing_fee_usd ]
      end

      def approximate_missing_refund_values( reference_transaction, attributes )
        if attributes[ :currency ].present?
          # Discount must be recalculated to account for any rounding
          # that may have been done by the provider.
          attributes[ :discount ] = attributes[ :subtotal ] -
                                    attributes[ :total ] +
                                    attributes[ :tax ]

          if attributes[ :currency ] == 'USD'
            usd_missing_refund_values( attributes )
          else
            international_missing_refund_values( attributes, reference_transaction )
          end
        end

        attributes
      end

      def usd_missing_refund_values( attributes )
        attributes[ :subtotal_usd ] = attributes[ :subtotal ]
        attributes[ :discount_usd ] = attributes[ :discount ]
        attributes[ :tax_usd ] =      attributes[ :tax ]
        attributes[ :total_usd ] =    attributes[ :total ]
      end

      def international_missing_refund_values( attributes, reference_transaction )
        if attributes[ :subtotal ] == reference_transaction.subtotal.to_f * -1
          # Full refund

          attributes[ :subtotal_usd ] = reference_transaction.subtotal_usd.to_f * -1
          attributes[ :discount_usd ] = reference_transaction.discount_usd.to_f * -1
          attributes[ :tax_usd ] =      reference_transaction.tax_usd.to_f * -1
          attributes[ :total_usd ] =    reference_transaction.total_usd.to_f * -1
        else
          # Partial refund

          # partial_refund_ratio will be a positive number
          partial_refund_ratio = attributes[ :subtotal ] / reference_transaction.subtotal.to_f * -1

          attributes[ :subtotal_usd ] = partial_refund_ratio * reference_transaction.subtotal_usd.to_f * -1
          attributes[ :discount_usd ] = partial_refund_ratio * reference_transaction.discount_usd.to_f * -1
          attributes[ :tax_usd ] =      partial_refund_ratio * reference_transaction.tax_usd.to_f * -1
          attributes[ :total_usd ] =    partial_refund_ratio * reference_transaction.total_usd.to_f * -1
        end
      end
    end
  end
end
