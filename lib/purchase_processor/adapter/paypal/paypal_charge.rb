module Unimatrix
  module PurchaseProcessor
    class PaypalCharge < Adapter
      include PayPal::SDK::REST
      include PayPal::SDK::Core::Logging

      include CurrencyHelper::ClassMethods

      def create_charge( customer: nil, amount:, offer:, currency:, metadata: nil, request_attributes:, source_type: nil )
        request_url = request_attributes[ :url ]
        request_referer = request_attributes[ :referer ]

        dealer_url = URI.parse( request_url )
        dealer_url = URI.join( dealer_url, '/' )

        referer_url = URI.parse( request_referer )
        referer_url = URI.join( referer_url, '/' )

        @payment = Payment.new(
          {
            :intent => 'sale',
            :payer => {
              :payment_method => 'paypal'
            },
            :redirect_urls => {
              :return_url => "#{ dealer_url }paypal/purchases/execute?redirect_uri=#{ CGI.escape( referer_url.to_s ) }",
              :cancel_url => "#{ dealer_url }paypal/purchases/cancel?redirect_uri=#{ CGI.escape( referer_url.to_s ) }",
            },
            :transactions => [
              {
                :item_list => {
                  :items => [
                    {
                      :name => offer.name,
                      :sku => offer.uuid,
                      :price => '%.2f' % amount,
                      :currency => currency,
                      :quantity => 1
                    }
                  ]
                },
                :amount => {
                  :total => '%.2f' % amount,
                  :currency => currency
                },
                :description => offer.name
              }
            ]
          }
        )

        # Create Payment and return the status(true or false)
        if @payment.create
          redirect_url = @payment.links.find{ |v| v.method == 'REDIRECT' }.href

          [ @payment, redirect_url ]
        else
          @payment
        end
      end

      def execute_charge( payment_id, payer_id, transaction, redirect_uri )
        @payment = Payment.find( payment_id )

        if @payment
          if @payment.execute( payer_id: payer_id )
            paypal_sale = @payment.transactions.first.related_resources.first.sale

            transaction.provider_id = paypal_sale.id rescue nil

            transaction.processing_fee =       paypal_sale.transaction_fee.value.to_f * -1 rescue 0.0

            if transaction.currency == 'USD'
              transaction.processing_fee_usd = transaction.processing_fee

              # processing_fee is a negative number
              revenue = transaction.subtotal -
                        transaction.discount +
                        transaction.processing_fee

              transaction.total_revenue =      revenue
              transaction.total_revenue_usd =  revenue
            else
              transaction.processing_fee_usd = exchange_to_usd( transaction.processing_fee, transaction.currency )

              # processing_fee and processing_fee_usd are negative numbers
              transaction.total_revenue =      transaction.subtotal -
                                               transaction.discount +
                                               transaction.processing_fee

              transaction.total_revenue_usd =  transaction.subtotal_usd -
                                               transaction.discount_usd +
                                               transaction.processing_fee_usd
            end

            transaction.type = PaypalPurchaseTransaction
            transaction.save

            [ true, "#{ redirect_uri }/success?provider=paypal&status=success&transaction_id=#{ transaction.id }" ]
          else
            transaction.type = PaypalFailedPurchaseTransaction
            transaction.save

            [ false, "#{ redirect_uri }?provider=paypal&status=error&message=#{ @payment.error.inspect }" ]
          end
        else
          transaction.type = PaypalFailedPurchaseTransaction
          transaction.save

          [ false, "#{ redirect_uri }?provider=paypal&status=error&message=PayPal internal error" ]
        end
      end

      def charge_successful?( charge )
        charge.present? && charge.state == 'created'
      end
    end
  end
end
