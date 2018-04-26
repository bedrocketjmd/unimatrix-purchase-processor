module Unimatrix
  module PurchaseProcessor
    class TransactionOrchestrator
      def self.create_transaction( provider, attributes, request_attributes = nil )
        name = self.name
        name = name.slice!( /(?<=Unimatrix::PurchaseProcessor::)(.*)(?=Orchestrator)/ )

        transaction = name.constantize.create( attributes )

        if transaction.save
          return OrchestratorSuccess.new( transaction )
        else
          return OrchestratorError.new(
            BadRequestError,
            transaction.errors.messages
          )
        end
      end

      def self.merge_tokens( attributes )
        if attributes[ :token ].present?
          token = attributes.delete( :token )
          attributes[ :source_type ] = token[ :object ] if token[ :object ].present? && attributes[ :provider ] == 'Stripe'
          attributes[ :source ] = token[ :id ] if token[ :id ].present? && attributes[ :provider ] == 'Stripe'
        end
        attributes
      end

      def self.apply_coupons( coupon_code, offer )
        if coupon_code && offer.price.to_f > 0.0
          coupon = Coupon.find_by( code: coupon_code )

          if coupon && coupon.active?
            coupon.apply( offer )
            coupon = coupon
            discount = coupon.discount
            [ coupon, discount ]
          else
           format_error( BadRequestError, 'Charge could not be completed successfully. The coupon does not exist or is no longer active.' )
          end
        else
          [ nil, 0.0 ]
        end
      end

      def self.attributes_block( provider, realm, customer, offer, product, subtotal, discount, currency, device_platform )
        attributes = {
          provider:        provider,
          realm:           realm,
          customer:        customer,
          offer:           offer,
          product:         product,
          subtotal:        subtotal,
          discount:        discount,
          currency:        currency,
          device_platform: device_platform
        }
        attributes
      end

      def self.tax_helper( realm, offer, customer, discount )
        @tax_helper ||= TaxHelper.new(
          realm: realm,
          offer: offer,
          customer: customer,
          discount: discount
        )
      end

      def self.format_error( error_type, error_message )
        OrchestratorError.new( error_type, error_message )
      end

      private_class_method :merge_tokens, :apply_coupons, :attributes_block, :tax_helper
    end
  end
end
