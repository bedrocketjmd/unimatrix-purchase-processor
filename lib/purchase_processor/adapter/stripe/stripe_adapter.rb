module Unimatrix
  module PurchaseProcessor
    class StripeAdapter < Adapter
      include CurrencyHelper

      #-------------------------------------------------------------------------------
      # class methods

      def self.retrieve_key( realm_uuid )
        test_setting = Rails.cache.fetch(
          [ realm_uuid, '_dealer_test_setting' ],
          expires_in: 10.minutes
        ) do
            settings = false

            if ENV[ 'RAILS_ENV' ] == 'test'
              settings = true
            else

            settings
          end
        end

        if test_setting
          ENV[ 'STRIPE_TEST_SECRET_KEY' ]
        else
          ENV[ 'STRIPE_SECRET_KEY' ]
        end
      end

      def self.transaction_from_webhook( event, provider_subscription=nil )
        adapter ||= StripeSubscription.new
        adapter.transaction_from_webhook( event )
      end

      def self.attributes_from_webhook( event )
        adapter ||= StripeAttribute.new
        adapter.attributes_from_webhook( event )
      end

      def self.attributes_from_metadata( object )
        adapter ||= StripeAttribute.new
        adapter.attributes_from_metadata( object )
      end

      def self.attributes_from_failed_invoice( attributes, object )
        adapter ||= StripeAttribute.new
        adapter.attributes_from_failed_invoice( attributes, object )
      end

      def self.subscription_from_event( event )
        adapter ||= StripeSubscription.new
        adapter.subscription_from_event( event )
      end

      def self.interpret_webhook( event, transaction, stripe_subscription, relation )
        adapter ||= StripeSubscription.new
        adapter.interpret_webhook( event, transaction, stripe_subscription, relation )
      end

      def self.transaction_valid?( transaction )
        transaction.present? && transaction.valid?
      end

      def self.pause_subscription( subscription )
        adapter = StripeSubscription.new
        adapter.pause_subscription( subscription )
      end

      def self.resume_subscription( subscription )
        adapter = StripeSubscription.new
        adapter.resume_subscription( subscription )
      end

      def create_plan( offer, realm )
        adapter = StripeSubscription.new
        adapter.create_plan( offer, realm )
      end

      def self.find_webhook_event( event_id )
        Stripe::Event.retrieve( event_id )
      end

      def self.valid_events
        [ 'invoice.payment_succeeded', 'invoice.payment_failed', 'customer.subscription.deleted',
          'charge.dispute.created', 'charge.dispute.funds_reinstated', 'charge.dispute.funds_withdrawn',
          'charge.dispute.updated','charge.dispute.closed' ]
      end

      #-------------------------------------------------------------------------------
      # instance methods

      def refresh_api_key( realm )
        Stripe.api_key = StripeAdapter.retrieve_key( realm.uuid )
        Stripe.api_version = "2016-02-19"
      end

      def provider_customer( customer  )
        @provider_customer ||= StripeCustomer.find_or_create( customer )
      end

      def customer_valid?( customer )
        customer.present? && provider_customer( customer ) && provider_customer( customer ).id.present?
      end

      def transation_valid?( transaction )
        transaction.present? && transaction.valid?
      end

      def create_charge( customer:, amount:, offer:, currency:, metadata:, request_attributes: nil, source_type: )
        adapter ||= StripeCharge.new
        adapter.create_charge(
          customer: customer,
          amount: amount,
          offer: offer,
          currency: currency,
          metadata: metadata,
          request_attributes: nil,
          source_type: source_type,
          stripe_customer: provider_customer( customer )
        )
      end

      def new_refund_transaction( reference_transaction, refund_attributes )
        adapter ||= StripeRefund.new
        adapter.new_refund_transaction( reference_transaction, refund_attributes )
      end

      def new_subscription( customer, device_platform, offer )
        adapter = StripeSubscription.new
        adapter.new_subscription( customer, device_platform, offer )
      end

      def charge_successful?( charge )
        adapter ||= StripeCharge.new
        adapter.charge_successful?( charge )
      end

      def subscription_successful?( subscriber )
        adapter ||= StripeSubscription.new
        adapter.subscription_successful?( subscriber )
      end

      def pay_delinquent_subscription( payments_subscription )
        adapter ||= StripeSubscription.new
        adapter.pay_delinquent_subscription( payments_subscription )
      end

      def new_purchase_transaction( attributes )
        StripePurchaseTransaction.new( attributes.merge( provider: 'Stripe' ) )
      end

      def self.generate_discount_coupon( discount, currency )
        discount_coupon = Stripe::Coupon.create(
          id: "#{ SecureRandom.hex }-discount_coupon",
          duration: "once",
          amount_off: ( discount * 100 ).to_i,
          currency: currency
        )

        discount_coupon
      end

      private

      def self.stripe_customer( customer )
        adapter ||= StripeCustomer.new
        adapter.stripe_customer( customer )
      end

      def self.attributes_from_invoice( object )
        adapter ||= StripeAttribute.new
        adapter.attributes_from_invoice( object )
      end

      def self.attributes_from_dispute( object )
        adapter ||= StripeAttribute.new
        adapter.attributes_from_dispute( object )
      end

      def self.attributes_from_charge( object )
        adapter ||= StripeAttribute.new
        adapter.attributes_from_charge( object )
      end

      def self.attributes_from_balance_transaction( balance_transaction )
        adapter ||= StripeAttribute.new
        adapter.attributes_from_balance_transaction( balance_transaction )
      end

      def self.attributes_from_subscription( object )
        adapter ||= StripeAttribute.new
        adapter.attributes_from_subscription( object )
      end

      def self.related_transaction_from_charge( charge )
        PurchaseTransaction.where( provider_id: charge ).first rescue nil
      end

      def self.attributes_from_related_transaction( related_transaction )
        adapter ||= StripeAttribute.new
        adapter.attributes_from_related_transaction( related_transaction )
      end

      def self.approximate_missing_values( attributes )
        adapter ||= StripeAttribute.new
        adapter.approximate_missing_values( attributes )
      end

      def self.format_stripe_money( cents, exponent )
        result = 0.0

        if cents.present?
          result = cents.to_f / exponent.to_f
        end

        result
      end
    end
  end
end
