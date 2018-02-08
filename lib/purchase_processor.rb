require 'configuration'

module Unimatrix
  class PurchaseProcessor < Configuration
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

require 'adapter/free/free_adapter'
require 'adapter/paypal/paypal_adapter'
require 'adapter/stripe/stripe_adapter'
