require 'singleton'

module Unimatrix
  class Configuration
    include Singleton

    def self.set_local_product_name( app_name )
      app_products = {
        merchant: 'realm_product',
        dealer:   'customer_product'
      }
      app_products[ app_name.to_sym ]
    end

    def self.field( field_name, options={} )
      class_eval(
        "def #{ field_name }( *arguments ); " +
           "@#{ field_name } = arguments.first unless arguments.empty?; " +
           "@#{ field_name } || " +
             ( options[ :default ].nil? ?
                "nil" :
                ( options[ :default ].is_a?( String ) ?
                    "'#{ options[ :default ] }'" :
                      "#{ options[ :default ] }" ) ) + ";" +
        "end",
        __FILE__,
        __LINE__
      )
    end

    field :local_product_name,  default: set_local_product_name( ENV[ 'APPLICATION_NAME' ] )
  end
end
