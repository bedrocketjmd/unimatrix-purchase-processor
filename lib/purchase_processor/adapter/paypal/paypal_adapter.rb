module Unimatrix
  module  PurchaseProcessor
    class PaypalAdapter < Adapter
      include PayPal::SDK::REST
      include PayPal::SDK::Core::Logging
      include CurrencyHelper
      #-------------------------------------------------------------------------------
      # class methods

      def self.execute_charge( payment_id, payer_id, transaction, redirect_uri )
        adapter ||= PaypalCharge.new
        adapter.execute_charge( payment_id, payer_id, transaction, redirect_uri )
      end

      def self.transaction_from_webhook( event, provider_subscription )
        case event.event_type

        when 'PAYMENT.SALE.COMPLETED'
          if zero_balance?( provider_subscription )
            PaypalPurchaseTransaction, 'complete'
          else
            PaypalPurchaseTransaction, 'failed'
          end
        when 'PAYMENT.SALE.DENIED'
          PaypalPurchaseTransaction, 'failed'

        when 'BILLING.SUBSCRIPTION.CANCELLED'
          PaypalPurchaseCancellationTransaction, nil

        when 'CUSTOMER.DISPUTE.CREATED'
          PaypalDisputeCreatedTransaction, nil

        when 'CUSTOMER.DISPUTE.UPDATED'
          PaypalDisputeUpdatedTransaction, nil

        when 'CUSTOMER.DISPUTE.RESOLVED'
          PaypalDisputeClosedTransaction, nil

        else
          nil, nil
        end
      end

      def self.attributes_from_webhook( event )
        adapter ||= PaypalAttribute.new
        adapter.attributes_from_webhook( event )
      end

      def self.attributes_from_metadata( event, payments_subscription )
        adapter ||= PaypalAttribute.new
        adapter.attributes_from_metadata( event, payments_subscription )
      end

      def self.attributes_from_sale( object )
        adapter ||= PaypalAttribute.new
        adapter.attributes_from_sale( object )
      end

      def self.attributes_from_dispute( object )
        adapter ||= PaypalAttribute.new
        adapter.attributes_from_dispute( object )
      end

      def self.payment_sale_completed( transaction, agreement, relation )
        if PaypalAdapter.transaction_valid?( transaction )
          agreement_details = agreement.agreement_details
          unless agreement_details.next_billing_date.nil?
            relation.update( expires_at: Time.parse( agreement_details.next_billing_date ) )
          end
          # if its the first time subscription - subscription confirmation email
          payments = relation.payments_subscription.successful_transactions.count
          if payments.present? && payments >= 1
            mailer_method = :payment_received
            subject_line = "We received your payment for #{ transaction.offer.name }"
          else
            mailer_method = :purchase_confirmation
            subject_line = "Thanks for your order!"
          end

          unless relation.payments_subscription.state == 'active'
            relation.payments_subscription.resume_subscription
          end

          relation.save
          TransactionMailer.send(
            mailer_method, transaction, subject_line
          ).deliver_now
        end
      end

      def self.payment_sale_denied( transaction, agreement, relation )
        if PaypalAdapter.transaction_valid?( transaction )
          #if payment fails, expire the CustomerProducts
          if relation.expires_at > Time.now
            relation.update( expires_at: Time.now )
          end

          unless relation.payments_subscription.state == 'inactive'
            relation.payments_subscription.pause_subscription
          end

          subject_line = "Your subscription has been suspended"
          payments_subscription = relation.payments_subscription

          PaymentsSubscriptionMailer.payments_subscription_suspended(
            payments_subscription, subject_line, transaction, agreement
          ).deliver_now
        end
      end

      def self.billing_subscription_cancelled( agreement_details, transaction, relation )
        if PaypalAdapter.transaction_valid?( transaction ) &&
          agreement_details[ "state" ].downcase == "cancelled"

          PaypalAdapter.pause_subscription( agreement )

          relation.update( expires_at: Time.parse( event.resource[ "agreement_details" ][ "last_payment_date" ] ) )

          PaymentsSubscriptionMailer.payments_subscription_cancelled(
            relation.payments_subscription,
            "Your subscription has been cancelled"
          ).deliver_now
        end
      end

      def self.pause_subscription( agreement )
        adapter ||= PaypalSubscription.new
        adapter.pause_subscription( agreement )
      end

      def self.resume_subscription( agreement )
        adapter ||= PaypalSubscription.new
        adapter.resume_subscription( agreement )
      end

      def self.execute_agreement( token )
        adapter ||= PaypalSubscription.new
        adapter.execute_agreement( token )
      end

      def self.find_webhook_event( resource_id )
        adapter ||= PaypalSubscription.new
        adapter.find_webhook_event( resource_id )
      end

      def self.subscription_from_event( event )
        adapter ||= PaypalSubscription.new
        adapter.billing_agreement_from_event( event )
      end

      def self.zero_balance?( provider_subscription )
        adapter ||= PaypalSubscription.new
        adapter.zero_balance?( provider_subscription )
      end

      def self.interpret_webhook( event, transaction, provider_subscription, relation )
        case event.event_type
          when 'PAYMENT.SALE.COMPLETED'
            if zero_balance?( provider_subscription )
              PaypalAdapter.payment_sale_completed( transaction, provider_subscription, relation )
            else
              PaypalAdapter.payment_sale_denied( transaction, provider_subscription, relation )
            end
          when 'PAYMENT.SALE.DENIED'
            PaypalAdapter.payment_sale_denied( transaction, provider_subscription, relation )
          when 'BILLING.SUBSCRIPTION.CANCELLED'
            PaypalAdapter.billing_subscription_cancelled( event.resource[ "agreement_details" ], transaction, relation )
        end
      end

      #-------------------------------------------------------------------------------
      # instance methods

      def customer_valid?( customer )
        customer.present?
      end

      def new_refund_transaction( reference_transaction, refund_attributes )
        adapter ||= PaypalRefund.new
        adapter.new_refund_transaction( reference_transaction, refund_attributes )
      end

      def new_subscription( customer, device_platform, offer )
        adapter ||= PaypalSubscription.new
        adapter.new_subscription( customer, device_platform, offer )
      end

      def create_charge( customer: nil, amount:, offer:, currency:, metadata: nil, request_attributes:, source_type: nil )
        adapter ||= PaypalCharge.new
        adapter.create_charge(
          customer: customer,
          amount: amount,
          offer: offer,
          currency: currency,
          metadata: metadata,
          request_attributes: request_attributes,
          source_type: source_type
        )
      end

      def charge_successful?( charge )
        charge.present? && charge.state == 'created'
      end

      def subscription_successful?( subscriber )
        subscriber.present? && subscriber.plan.state.downcase == 'active'
      end

      def pay_delinquent_subscription( payments_subscription )
        adapter ||= PaypalSubscription.new
        adapter.pay_delinquent_subscription( payments_subscription )
      end

      def new_purchase_transaction( attributes )
        PaypalPurchaseTransaction.new( attributes.merge( { provider: 'Paypal', state: 'pending' } ) )
      end

      def create_plan( offer, request )
        adapter ||= PaypalSubscription.new
        adapter.create_plan( offer, request )
      end

      def create_agreement( payments_subscription_attributes, request_attributes )
        adapter ||= PaypalSubscription.new
        adapter.create_agreement( payments_subscription_attributes, request_attributes )
      end

      private

      def self.transaction_valid?( transaction )
        transaction.present? && transaction.valid?
      end

      def self.transaction_information_from_webhook( payments_subscription )
        adapter ||= PaypalAttribute.new
        adapter.transaction_information_from_webhook( payments_subscription )
      end

      def self.attributes_from_charge( object )
        adapter ||= PaypalAttribute.new
        adapter.attributes_from_charge( object )
      end

      def self.approximate_missing_purchase_values( attributes )
        adapter ||= PaypalAttribute.new
        adapter.approximate_missing_purchase_values( attributes )
      end

      def self.approximate_missing_refund_values( reference_transaction, attributes )
        adapter ||= PaypalRefund.new
        adapter.approximate_missing_refund_values( reference_transaction, attributes )
      end

      def self.valid_events
        [ 'PAYMENT.SALE.COMPLETED', 'PAYMENT.SALE.DENIED', 'BILLING.SUBSCRIPTION.CANCELLED',
          'CUSTOMER.DISPUTE.CREATED', 'CUSTOMER.DISPUTE.UPDATED', 'CUSTOMER.DISPUTE.RESOLVED' ]
      end
    end
  end
end
