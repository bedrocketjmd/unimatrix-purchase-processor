module Unimatrix
  module PurchaseProcessor
    class OrchestratorResponse
      attr_reader :success, :transaction, :redirect_url, :error_class, :message

      def initialize( success, transaction=nil, redirect_url=nil, error_class=nil, message=nil )
        @success      = success
        @transaction  = transaction
        @redirect_url = redirect_url
        @error_class  = error_class
        @message      = message
      end
    end
  end
end
