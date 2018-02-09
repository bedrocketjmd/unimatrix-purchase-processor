module Unimatrix
  module PurchaseProcessor
    class Adapter < Configuration
      def self.configuration( &block )
        Configuration.instance().instance_eval( &block ) unless block.nil?
        Configuration.instance()
      end

      def self.local_product( resource )
        product_name = set_local_product_name
        if resource.respond_to?( product_name )
          resource.send( product_name )
        end
      end

      def self.set_local_product_name
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
