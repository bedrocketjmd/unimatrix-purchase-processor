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
