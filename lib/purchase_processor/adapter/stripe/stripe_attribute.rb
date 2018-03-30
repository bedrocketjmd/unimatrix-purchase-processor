module Unimatrix
  module PurchaseProcessor
    class StripeAttribute < Adapter
      include CurrencyHelper::ClassMethods

      def attributes_from_webhook( event )
        object = event.data.object
        object_name = object.object

        attributes = {}

        if object.try( :subscription )
          payments_subscription = PaymentsSubscription.find_by( provider_id: object.subscription )
          attributes[ :payments_subscription_id ] = payments_subscription.id

          if Adapter.local_product_name == 'customer_product'
            attributes[ :payments_subscription_uuid ] = payments_subscription.uuid
          end

          # dynamically assigns id of either a realm_product, or customer_product, depending on application
          attributes[ "#{ Adapter.local_product_name }_id".to_sym ] = Adapter.local_product( payments_subscription ).id
        end

        if object.try(:lines)
          metadata = object.lines.first.metadata
        else
          metadata = object.metadata
        end

        if metadata.present? && metadata.to_h.present?
          attributes.merge!( StripeAdapter.attributes_from_metadata( metadata ) )
        end

        unless event.type.include?( 'failed' )
          if [ 'charge', 'invoice', 'dispute', 'subscription' ].include? object_name
            attributes = StripeAdapter.send( "attributes_from_#{ object_name }", object ).
                           merge( attributes )
          end

          if attributes[ :tax ].nil?
            tax = PurchaseTransaction.where( provider_id: object.charge ).first.tax
            attributes[ :tax ] = tax
          end

          StripeAdapter.approximate_missing_values( attributes )
        else
          attributes.merge!( StripeAdapter.attributes_from_failed_invoice( attributes, object ) )
        end
      end

      def attributes_from_metadata( object )
        begin
          if object.try( :realm_id )
            realm = Realm.find_by( id: object.realm_id.to_i )
            realm_id = realm.id
            realm_uuid realm.uuid
          elsif object.try( :realm_uuid )
            realm = Realm.find_by( uuid: object.realm_uuid )
            realm_id = realm.id
            realm_uuid = realm.uuid
          else
            realm_id = nil
          end

          attributes = {
            realm_id: realm_id,
            offer_id: object.offer_id.to_i,
            product_id: object.product_id.to_i,
            customer_id: object.customer_id.to_i,
            device_platform: object.device_platform,
            provider: object.provider,
            subtotal: object.subtotal.to_f,
            subtotal_usd: object.subtotal_usd.to_f,
            tax: object.tax.to_f,
            total: object.total.to_f
          }

          if Adapter.local_product_name == 'customer_product'
            attributes.merge!(
              offer_uuid: Offer.find( attribtes[ :offer_id ] ).uuid,
              product_uuid: Product.find( attributes[ :product_id ] ).uuid,
              customer_uuid: Customer.find( attributes[ :customer_id ] ).uuid,
            )

            attributes.delete( :realm_id )
          end

          attributes
        rescue
          {}
        end
      end

      def attributes_from_invoice( object )
        begin
          attributes = {}

          if object.charge.present?
            charge = Stripe::Charge.retrieve( object.charge )
            attributes.merge!( StripeAdapter.attributes_from_charge( charge ) )
          end

          subscription = object.lines.data.select { | item | item.type == 'subscription' }
          subscription = subscription.first
          attributes.merge!( StripeAdapter.attributes_from_metadata( subscription.metadata ) )
          exponent = exponent_from_currency( object.currency )

          attributes.merge(
            subtotal:          StripeAdapter.format_stripe_money( object.subtotal, exponent ),
            tax:               StripeAdapter.format_stripe_money( object.tax, exponent ),
            tax_percent:       object.tax_percent,
            total:             StripeAdapter.format_stripe_money( object.total, exponent )
          )
        rescue
          {}
        end
      end

      def attributes_from_dispute( object )
        begin
          exponent = exponent_from_currency( object.currency )
          attributes = {
            response_code: object.reason,
            response_message: object.status,
            subtotal: StripeAdapter.format_stripe_money( object.amount, exponent )
          }
          related_transaction = nil

          if object.charge.present?
            charge = Stripe::Charge.retrieve( object.charge )
            attributes.merge!( StripeAdapter.attributes_from_charge( charge ) )
            related_transaction = StripeAdapter.related_transaction_from_charge( charge.id )
          end

          if related_transaction.present?
            attributes[:transaction_id] = related_transaction.id
            attributes.merge!( StripeAdapter.attributes_from_related_transaction( related_transaction ) )
          end

          if object.balance_transactions.present?
            balance_transaction = object.balance_transactions.first
            attributes.merge!( StripeAdapter.attributes_from_balance_transaction( balance_transaction ) )
          end

          attributes
        rescue
          {}
        end
      end

      def attributes_from_charge( object )
        balance_transaction = nil

        if object.source.object == 'source'
          card = object.source.card
        else
          card = object.source
        end

        attributes = {
          currency:            object.currency.upcase,
          provider_id:         object.id,
          payment_method:      card.brand,
          payment_identifier:  card.last4,
          total:               StripeAdapter.format_stripe_money( object.amount,
                                             exponent_from_currency( object.currency ) )
        }

        if object.balance_transaction
          balance_transaction = Stripe::BalanceTransaction.
                                    retrieve( object.balance_transaction )
        end

        attributes.merge( StripeAdapter.attributes_from_balance_transaction( balance_transaction ) )
      end

      def attributes_from_balance_transaction( balance_transaction )
        result = {}

        if balance_transaction.present?

          default_exponent = exponent_from_currency( balance_transaction.currency )

          result = {
            processing_fee_usd: StripeAdapter.format_stripe_money( balance_transaction.fee, default_exponent ) * -1,
            total_usd:          StripeAdapter.format_stripe_money( balance_transaction.amount, default_exponent )
          } rescue {}
        end

        result
      end

      def attributes_from_subscription( object )
        begin
          expiry = Time.at( object.current_period_end )
          at_period_end = object.cancel_at_period_end

          attributes = {
            stripe_subscription_expires_at: expiry,
            stripe_subscription_at_period_end: at_period_end
          }
          attributes.merge!( StripeAttributes.attributes_from_metadata( object.metadata ) )

        rescue
          {}
        end
      end

      def attributes_from_related_transaction( related_transaction )
        {
          realm_id: related_transaction.realm_id,
          offer_id: related_transaction.offer_id,
          product_id: related_transaction.product_id,
          customer_id: related_transaction.customer_id,
          tax: related_transaction.tax,
          tax_usd: related_transaction.tax_usd,
          tax_percent: related_transaction.tax_percent,
          subtotal_usd: related_transaction.subtotal_usd
        }
      end

      def attributes_from_failed_invoice( attributes, object )
        charge = Stripe::Charge.retrieve( object.charge )

        if charge && charge.source
          if charge.source.card
            card = charge.source.card

            attributes = {
              provider_id: object.charge,
              payment_method: card.brand,
              payment_identifier: card.last4
            }
          end
        end
      end

      def approximate_missing_values( attributes )
        if attributes[ :currency ].present?
          # Discount must be recalculated to account for any rounding
          # that may have been done by the provider.
          attributes[ :discount ] = attributes[ :subtotal ] -
                                    attributes[ :total ] +
                                    attributes[ :tax ]

          if attributes[ :discount ].round( 2 ).to_f == 0.0
            attributes[ :discount ] = 0.0
          end

          if attributes[ :currency ] == 'USD'
            attributes[ :subtotal_usd ] =      attributes[ :subtotal ]
            attributes[ :discount_usd ] =      attributes[ :discount ]
            attributes[ :tax_usd ] =           attributes[ :tax ]

            # Processing fee is reversed because that's how it's returned from Stripe
            attributes[ :processing_fee ] =    attributes[ :processing_fee_usd ]

            # processing_fee is a negative number
            revenue = attributes[ :subtotal ] -
                      attributes[ :discount ] +
                      attributes[ :processing_fee ]

            attributes[ :total_revenue ] =     revenue
            attributes[ :total_revenue_usd ] = revenue
          else
            total_usd = attributes[ :total_usd ]
            total = attributes[ :total ]

            attributes[ :subtotal_usd ] =      exchange_by_ratio( attributes[ :subtotal ], total, total_usd, 'USD' )
            attributes[ :discount_usd ] =      exchange_by_ratio( attributes[ :discount ], total, total_usd, 'USD' )
            attributes[ :tax_usd ] =           exchange_by_ratio( attributes[ :tax ], total, total_usd, 'USD' )

            # Processing fee is reversed because that's how it's returned from Stripe
            attributes[ :processing_fee ] =    exchange_by_ratio( attributes[ :processing_fee_usd ], total, total_usd )


            # processing_fee and processing_fee_usd are negative numbers
            attributes[ :total_revenue ] =     attributes[ :subtotal ] -
                                               attributes[ :discount ] +
                                               attributes[ :processing_fee ]

            attributes[ :total_revenue_usd ] = attributes[ :subtotal_usd ] -
                                               attributes[ :discount_usd ] +
                                               attributes[ :processing_fee_usd ]
          end
        end

        attributes
      end
    end
  end
end
