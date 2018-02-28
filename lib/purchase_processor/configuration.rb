require 'singleton'

module Unimatrix
  module PurchaseProcessor
    class Configuration
      include Singleton

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

      field :application_name, default: nil
    end
  end
end
