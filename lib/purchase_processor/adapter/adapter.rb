module Unimatrix
  module PurchaseProcessor
    class Adapter < Configuration
      def self.configuration( &block )
        Configuration.instance().instance_eval( &block ) unless block.nil?
        Configuration.instance()
      end

      def self.local_product( resource )
        product_name = configuration.local_product_name
        if resource.respond_to?( product_name )
          resource.send( product_name )
        end
      end
    end
  end
end
