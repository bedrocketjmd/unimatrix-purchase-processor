require 'money/bank/google_currency'

# Set the seconds after than the current rates are automatically expired
# By default, they never expire
Money::Bank::GoogleCurrency.ttl_in_seconds = 86400

# Set default bank to instance of GoogleCurrency
Money.default_bank = Money::Bank::GoogleCurrency.new

module CurrencyHelper
  extend ActiveSupport::Concern

  module ClassMethods
    def exchange_by_ratio( value, total, total_usd, result_currency=nil )
      if result_currency == 'USD'
        value * ( total_usd / total ) # To USD
      else
        value * ( total / total_usd ) # from USD
      end
    end

    def exchange_to_usd( value, original_currency )
      return 0.0 if !value

      exponent = exponent_from_currency( original_currency )

      money = Money.new( value * exponent, original_currency ) # amount is in cents
      exchanged = money.exchange_to( :USD )
      exchanged.fractional / 100.00
    end

    def exponent_from_currency( currency )
      10 ** ( Money::Currency.new( currency ).exponent.to_i ) rescue 1
    end
  end
end
