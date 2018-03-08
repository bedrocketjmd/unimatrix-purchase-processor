module Unimatrix
  module PurchaseProcessor
    class Adapter
      def self.configuration( &block )
        Configuration.instance().instance_eval( &block ) unless block.nil?
        Configuration.instance()
      end

      def self.local_product( resource )
        if local_product_name && resource.respond_to?( local_product_name )
          resource.send( local_product_name )
        end
      end

      def self.local_product_name
        app_name = configuration.application_name.to_sym
        unless app_name.nil?
          app_products = {
            merchant: 'realm_product',
            dealer:   'customer_product'
          }
          app_products[ app_name ]
        end
      end
    end
  end
end
