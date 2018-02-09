module Unimatrix
  module PurchaseProcessor
    class StripeSubscription < Adapter
      def transaction_from_webhook( event )
        case event.type

        when 'invoice.payment_succeeded'
          StripePurchaseTransaction

        when 'invoice.payment_failed'
          StripeFailedPurchaseTransaction

        when 'customer.subscription.deleted'
          StripePurchaseCancellationTransaction

        when 'charge.dispute.created'
          StripeDisputeCreatedTransaction

        when 'charge.dispute.funds_reinstated'
          StripeDisputeFundsReinstatedTransaction

        when 'charge.dispute.funds_withdrawn'
          StripeDisputeFundsWithdrawnTransaction

        when 'charge.dispute.updated'
          StripeDisputeUpdatedTransaction

        when 'charge.dispute.closed'
          StripeDisputeClosedTransaction

        else
          nil
        end
      end

      def pause_subscription( subscription )
        unless subscription.status != "active"
          pause_coupon = Stripe::Coupon.create(
            id: "#{ SecureRandom.hex }-suspension-coupon",
            duration: "forever",
            percent_off: 100
          )
          subscription.coupon = pause_coupon.id
          subscription.save
        else
          return "Subscription #{ subscription.id } cannot be suspended"
        end
      end

      def resume_subscription( subscription )
        if subscription.status == "active" && subscription.discount.present? &&
        subscription.discount.coupon.id == "#{ subscription.id }-suspension-coupon"
          subscription.delete_discount()
          coupon = Stripe::Coupon.retrieve( "#{ subscription.id }-suspension-coupon" )
          coupon.delete
        else
          return "Subscription #{ subscription.id } could not be reactive -- check error logs"
        end
      end

      def new_subscription( customer, device_platform, offer )
        PaymentsSubscription.new( customer: customer, provider: 'Stripe', device_platform: device_platform, offer: offer )
      end

      def create_plan( offer, realm )
        if offer.trial_period
          cycles = {
            "1 day" => 1,
            "1 week" => 7,
            "1 month" => 30
          }
          trial_period = cycles[ offer.period ] || offer.trial_period.split(" ").first.to_i
        else
          trial_period = nil
        end
        offer_description =
          if offer.description.empty?
            "AS Roma Video"
          else
            offer.description.truncate( 22 )
          end
        Stripe::Plan.create(
          amount: ( offer.price * offer.currency_exponent ).to_i,
          interval: offer.period,
          interval_count: 1,
          trial_period_days: trial_period,
          name: offer.name,
          currency: offer.currency,
          id: "#{ offer.code_name }-#{ offer.uuid }",
          statement_descriptor:  offer_description,
          metadata: {
            realm_uuid: realm.uuid,
            offer_id: offer.id
          }
        )
      end

      def subscription_from_event( event )
        result = nil
        object = event.data.object
        if object.object == 'subscription'
          result = event.data.object
        elsif object.object == 'invoice'
          result = object.lines.data.select { | item | item.type == 'subscription' }
          customer = Stripe::Customer.retrieve( object.customer )
          result = customer.subscriptions.retrieve( result.first.id ) rescue nil
        end
        result
      end

      def subscription_successful?( subscriber )
        subscriber.present? && [ 'succeeded', 'active', 'trialing' ].include?( subscriber.status )
      end

      def interpret_webhook( event, transaction, stripe_subscription, relation )
        case event.type
        when 'invoice.payment_succeeded'
          StripeSubscription.process_successful_invoice( transaction, stripe_subscription, relation )
        when 'invoice.payment_failed'
          StripeSubscription.process_failed_invoice( transaction, stripe_subscription, relation )
        when 'customer.subscription.deleted'
          # if it was canceled by stripe immediately, its because there was a failure to pay
          StripeSubscription.process_cancelled_subscription( event, transaction, stripe_subscription, relation  )
        end
      end

      def pay_delinquent_subscription( payments_subscription )
        adapter = StripeAdapter.new

        adapter.refresh_api_key( payments_subscription.offer.realm )

        provider_subscription = payments_subscription.retrieve_subscription

        customer = adapter.provider_customer( payments_subscription.customer )

        delinquent_invoice = customer.invoices.data.detect { | invoice | !invoice.paid &&
          invoice.subscription == provider_subscription.id  }

        if delinquent_invoice && delinquent_invoice.closed
          delinquent_invoice.closed = false
          delinquent_invoice.save
        end

        begin
          delinquent_invoice.pay( source: customer.default_source )
        rescue => error
          delinquent_invoice
        end

        if delinquent_invoice && delinquent_invoice.paid && delinquent_invoice.closed
          payments_subscription.resume_subscription
          relation = payments_subscription.customer_product
          relation.update( expires_at: Time.at( provider_subscription.current_period_end ) )
        end
        payments_subscription
      end

      private

      def self.process_successful_invoice( transaction, stripe_subscription, relation )
        if StripeAdapter.transaction_valid?( transaction )
          new_expiry = Time.at( stripe_subscription.current_period_end )
          # if its the first time subscription - subscription confirmation email
          payments = relation.successful_payments
          if payments.present? && payments >= 1
            relation.successful_payments =+ 1
            mailer_method = :payment_received
            subject_line = "We received your payment for #{ transaction.offer.name }"
          else
            relation.successful_payments = 1
            mailer_method = :purchase_confirmation
            subject_line = "Thanks for your order!"
          end
          relation.expires_at = new_expiry

          unless relation.payments_subscription.state == 'active'
            relation.payments_subscription.resume_subscription
          end

          relation.save
          TransactionMailer.send(
            mailer_method, transaction, subject_line
          ).deliver_now
        end
      end

      def self.process_failed_invoice( transaction, stripe_subscription, relation )
        if StripeAdapter.transaction_valid?( transaction )
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
            payments_subscription, subject_line, transaction, stripe_subscription
          ).deliver_now
        end
      end

      def self.process_cancelled_subscription( event, transaction, stripe_subscription, relation  )
        if StripeAdapter.transaction_valid?( transaction ) &&
           event.request == nil &&
           ( stripe_subscription.canceled_at == stripe_subscription.ended_at )

           relation.update( expires_at: Time.at( stripe_subscription.ended_at ) )

           relation.payments_subscription.pause_subscription( true )

           PaymentsSubscriptionMailer.payments_subscription_cancelled(
             relation.payments_subscription, "Your subscription has been cancelled"
           ).deliver_now
        end
      end
    end
  end
end
