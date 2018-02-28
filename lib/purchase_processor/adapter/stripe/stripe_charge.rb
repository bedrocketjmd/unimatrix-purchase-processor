module Unimatrix
  module PurchaseProcessor
    class StripeCharge < Adapter
      include CurrencyHelper::ClassMethods

      def create_charge( customer:, amount:, offer:, currency:, metadata:, request_attributes: nil, source_type:, stripe_customer: )
        begin
          charge_attributes = {
            source:      metadata.delete( :source ),
            amount:      ( amount * offer.currency_exponent ).to_i, # in cents
            description: offer.name,
            currency:    currency,
            metadata:    metadata.to_h
          }

          if source_type == 'source'
            charge_attributes.merge!( customer: stripe_customer )
          end

          Stripe::Charge.create( charge_attributes )
        rescue Stripe::CardError => error
          error
        end
      end

      def charge_successful?( charge )
        charge.present? && [ 'succeeded', 'active', 'trialing' ].include?( charge.status )
      end
    end
  end
end
