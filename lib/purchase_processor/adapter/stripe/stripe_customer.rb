module Unimatrix
  module PurchaseProcessor
    class StripeCustomer < Adapter
      def stripe_customer( customer )
        @stripe_customer ||= StripeAdapter.provider_customer( customer )
      end

      def self.find_or_create( customer )
        if Stripe.api_key.nil?
          adapter = StripeAdapter.new
          adapter.refresh_api_key( customer.realm )
        end

        result = nil

        attributes = {
          email: ( customer.email_address rescue '' ),
          metadata: {
            name: ( customer.name rescue '' ),
            realm_uuid: customer.realm.uuid,
            customer_id: customer.id
          }
        }

        if customer.stripe_customer_uuid.present?
          begin
            result = Stripe::Customer.retrieve( customer.stripe_customer_uuid )
            attributes.each { | attribute, value | result.send( "#{attribute}=", value ) }
            result.save
          rescue => error
            Rails.logger.error( "Stripe: #{error.inspect}" )
            result = Stripe::Customer.create( attributes )
          end
        else
          result = Stripe::Customer.create( attributes )
        end

        customer_resources = customer.resources
        customer_resources.merge!( { stripe_customer_uuid: result.id } )

        customer.update( resources: customer_resources )
        result
      end

      def self.retrieve_card( customer )
        card = { name: '', number: '', exp_month: '', exp_year: '', cvc: '' }

        if customer.stripe_customer_uuid.blank?
          message = 'Customer does not have a stripe uuid.'
          return { card: card, message: message }
        end

        stripe_customer = Stripe::Customer.retrieve( customer.stripe_customer_uuid )
        if stripe_customer.sources.data.blank? ||
           stripe_customer.default_source.blank?
          message = 'Customer does not have a stored credit card.'
          return { card: card, message: message }
        end

        begin
          stripe_card = stripe_customer.sources.retrieve( stripe_customer.default_source )
          if stripe_card.is_a?( Stripe::Card )
            card = {
              name: stripe_card.name,
              number: "**** **** **** #{stripe_card.last4}",
              exp_month: stripe_card.exp_month,
              exp_year: stripe_card.exp_year.to_s.slice(2,4),
              cvc: '***'
            }
          else
            message = 'Stripe: Error retrieving card information.'
          end
        rescue => error
          message = "Stripe: #{error.inspect}"
        end

        { card: card, message: message }
      end

      def self.retrieve_all_sources( customer )
        stripe_customer = StripeCustomer.find_or_create( customer )
        formatted_sources = []

        if stripe_customer
          sources = stripe_customer.sources.data

          sources.each do | source |
            if source.object == 'source'
              formatted_sources.push(
                {
                  id: source.id,
                  client_secret: source.client_secret,
                  default_source: source.id == stripe_customer.default_source
                }
              )
            end
          end
        end

        formatted_sources
      end

      def self.remove_source( customer, source )
        stripe_customer = StripeCustomer.find_or_create( customer )

        if stripe_customer
          stripe_customer.sources.retrieve( source ).delete
        end

        stripe_customer
      end

      def self.update_default_source( customer, source )
        stripe_customer = StripeCustomer.find_or_create( customer )

        if stripe_customer
          stripe_customer.default_source = source[ 'id' ]
          stripe_customer.save
        end

        stripe_customer
      end

      def self.add_new_source( customer, source )
        stripe_customer = StripeCustomer.find_or_create( customer )

        if stripe_customer
          stripe_customer.sources.create( source: source[ 'id' ] )
        end

        stripe_customer
      end

      def self.stripe_customer( customer )
        @stripe_customer ||= StripeCustomer.find_or_create( customer )
      end

      def self.create_or_confirm_existing_source( adapter, customer, attributes )
        begin
          stripe_customer = adapter.provider_customer( customer ) if adapter.respond_to? ( :provider_customer )

          if stripe_customer
            customer_cards = stripe_customer.sources.data
            source = Stripe::Source.retrieve( attributes[ :source ] )

            existing_card = customer_cards.detect do | customer_source |
              if customer_source[ 'card' ]
                customer_source.card.fingerprint == source.card.fingerprint &&
                customer_source.card.exp_month == source.card.exp_month &&
                customer_source.card.exp_year == source.card.exp_year
              end
            end

            if !existing_card
              stripe_customer.sources.create( { :source => attributes[ :source ] } )
            end

            stripe_customer
          end
        rescue Stripe::CardError => error
          error
        end
      end
    end
  end
end
