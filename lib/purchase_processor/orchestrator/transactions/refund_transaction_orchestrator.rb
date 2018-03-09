module Unimatrix
  module PurchaseProcessor
    class RefundTransactionOrchestrator < TransactionOrchestrator
      def self.create_transaction( provider, attributes, request_attributes = nil )
        orchestrator_response = nil

        attributes[ :provider ] = provider

        unless attributes.is_a?( ActionController::Parameters ) ||
               attributes.is_a?( ActiveSupport::HashWithIndifferentAccess )
          attributes.symbolize_keys!
        end

        reference_transaction = PurchaseTransaction.
                                  find( attributes[ :transaction_id ] ) \
                                  rescue nil

        revoke_access = attributes.delete( :revoke_access )

        if reference_transaction.present?
          if reference_transaction.refundable?
            refund_attributes = attributes

            if refund_attributes[ :subtotal ] == reference_transaction.subtotal * -1
              # Full refund

              refund_attributes[ :tax ] =          reference_transaction.tax * -1
              refund_attributes[ :total ] =        reference_transaction.total * -1
            else
              # Partial refund

              # partial_refund_ratio will be a positive number
              partial_refund_ratio = refund_attributes[ :subtotal ] / reference_transaction.subtotal * -1

              refund_attributes[ :tax ] =      partial_refund_ratio * reference_transaction.tax * -1

              refund_attributes[ :total ] =    partial_refund_ratio * reference_transaction.total * -1
            end

            realm = Realm.find_by( id: attributes[ :realm_id ] )

            adapter = "Unimatrix::PurchaseProcessor::#{ provider }Adapter".constantize.new
            adapter.refresh_api_key( realm ) if adapter.respond_to?( :refresh_api_key )

            if refund_attributes.include?( :type_name )
              refund_attributes = refund_attributes.except( :type_name)
            end

            if refund_attributes.include?( :token )
              refund_attributes = refund_attributes.except( :token)
            end

            refund_transaction = adapter.new_refund_transaction( reference_transaction, refund_attributes )

            if refund_transaction.save
              if revoke_access
                local_product = Adapter.local_product( reference_transaction )
                local_product.update( expires_at: Time.now )
              end

              unless refund_transaction.type === 'FreeRefundTransaction'
                TransactionMailer.refund_processed(
                  refund_transaction,
                  'Your refund has been processed'
                ).deliver_now
              end
            else

              orchestrator_response = format_error( BadRequestError, refund_transaction.errors.messages )
            end

            orchestrator_response = orchestrator_response || OrchestratorSuccess.new( refund_transaction )
          else
            orchestrator_response = format_error( MissingParameterError, 'Reference transaction does not have a payment_id ' +
            'which is required for refunding, or the refund period has passed.' )
          end
        else
          orchestrator_response = format_error( NotFoundError, 'No purchase transaction exists with the reference id. Cannot refund.' )
        end
        return orchestrator_response
      end
    end
  end
end
