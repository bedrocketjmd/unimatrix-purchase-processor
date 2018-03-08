module Unimatrix
  module PurchaseProcessor
    class OrchestratorSuccess < OrchestratorResponse
      def initialize( transaction )
        super( true, transaction )
      end
    end
  end
end
