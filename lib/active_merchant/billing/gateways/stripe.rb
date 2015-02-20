require 'active_support/core_ext/hash/slice'
require 'grizzly_ber'

module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    class StripeGateway < Gateway
      # self.live_url = 'https://api.stripe.com/v1/'
      self.live_url = 'https://qa-edge-api.stripe.com/v1/'

      AVS_CODE_TRANSLATOR = {
        'line1: pass, zip: pass' => 'Y',
        'line1: pass, zip: fail' => 'A',
        'line1: pass, zip: unchecked' => 'B',
        'line1: fail, zip: pass' => 'Z',
        'line1: fail, zip: fail' => 'N',
        'line1: unchecked, zip: pass' => 'P',
        'line1: unchecked, zip: unchecked' => 'I'
      }

      CVC_CODE_TRANSLATOR = {
        'pass' => 'M',
        'fail' => 'N',
        'unchecked' => 'P'
      }

      # Source: https://support.stripe.com/questions/which-zero-decimal-currencies-does-stripe-support
      CURRENCIES_WITHOUT_FRACTIONS = ['BIF', 'CLP', 'DJF', 'GNF', 'JPY', 'KMF', 'KRW', 'MGA', 'PYG', 'RWF', 'VUV', 'XAF', 'XOF', 'XPF']

      self.supported_countries = %w(AT AU BE CA CH DE DK ES FI FR GB IE IT LU NL NO SE US)
      self.default_currency = 'USD'
      self.money_format = :cents
      self.supported_cardtypes = [:visa, :master, :american_express, :discover, :jcb, :diners_club]

      self.homepage_url = 'https://stripe.com/'
      self.display_name = 'Stripe'

      STANDARD_ERROR_CODE_MAPPING = {
        'incorrect_number' => STANDARD_ERROR_CODE[:incorrect_number],
        'invalid_number' => STANDARD_ERROR_CODE[:invalid_number],
        'invalid_expiry_month' => STANDARD_ERROR_CODE[:invalid_expiry_date],
        'invalid_expiry_year' => STANDARD_ERROR_CODE[:invalid_expiry_date],
        'invalid_cvc' => STANDARD_ERROR_CODE[:invalid_cvc],
        'expired_card' => STANDARD_ERROR_CODE[:expired_card],
        'incorrect_cvc' => STANDARD_ERROR_CODE[:incorrect_cvc],
        'incorrect_zip' => STANDARD_ERROR_CODE[:incorrect_zip],
        'card_declined' => STANDARD_ERROR_CODE[:card_declined],
        'processing_error' => STANDARD_ERROR_CODE[:processing_error]
      }

      def initialize(options = {})
        requires!(options, :login)
        # @api_key = options[:login]
        @api_key = 'sk_live_RVjPWJC6tN0Fx5E5C4SsWuxu'
        @fee_refund_api_key = options[:fee_refund_login]
        @version = options[:version]

        super
      end

      def authorize(money, payment, options = {})
        MultiResponse.run do |r|
          if payment.is_a?(ApplePayPaymentToken)
            r.process { tokenize_apple_pay_token(payment) }
            payment = StripePaymentToken.new(r.params["token"]) if r.success?
          end
          r.process do
            post = create_post_for_auth_or_purchase(money, payment, options)
            post[:capture] = "false" unless payment.respond_to?(:icc_data) && payment.icc_data.present?
            commit(:post, 'charges', post, options)
          end
        end.responses.last
      end

      # To create a charge on a card or a token, call
      #
      #   purchase(money, card_hash_or_token, { ... })
      #
      # To create a charge on a customer, call
      #
      #   purchase(money, nil, { :customer => id, ... })
      def purchase(money, payment, options = {})
        MultiResponse.run do |r|
          if payment.is_a?(ApplePayPaymentToken)
            r.process { tokenize_apple_pay_token(payment) }
            payment = StripePaymentToken.new(r.params["token"]) if r.success?
          end
          r.process do
            post = create_post_for_auth_or_purchase(money, payment, options)
            commit(:post, 'charges', post, options)
          end
        end.responses.last
      end

      def capture(money, authorization, options = {})
        post = {}

        # this block needs tests
        emv_tc_response = options.delete(:icc_data)
        post[:card] = {icc_data: GrizzlyBer.new(emv_tc_response).to_ber} if emv_tc_response

        add_amount(post, money, options)
        add_application_fee(post, options)

        commit(:post, "charges/#{CGI.escape(authorization)}/capture", post, options)
      end

      def void(identification, options = {})
        commit(:post, "charges/#{CGI.escape(identification)}/refund", {}, options)
      end

      def refund(money, identification, options = {})
        post = {}
        add_amount(post, money, options)
        post[:refund_application_fee] = true if options[:refund_application_fee]

        MultiResponse.run(:first) do |r|
          r.process { commit(:post, "charges/#{CGI.escape(identification)}/refund", post, options) }

          return r unless options[:refund_fee_amount]

          r.process { fetch_application_fees(identification, options) }
          r.process { refund_application_fee(options[:refund_fee_amount], application_fee_from_response(r.responses.last), options) }
        end
      end

      def verify(payment, options = {})
        MultiResponse.run(:use_first_response) do |r|
          r.process { authorize(50, payment, options) }
          r.process(:ignore_result) { void(r.authorization, options) }
        end
      end

      def application_fee_from_response(response)
        return unless response.success?

        application_fees = response.params["data"].select { |fee| fee["object"] == "application_fee" }
        application_fees.first["id"] unless application_fees.empty?
      end

      def refund_application_fee(money, identification, options = {})
        return Response.new(false, "Application fee id could not be found") unless identification

        post = {}
        add_amount(post, money, options)
        options.merge!(:key => @fee_refund_api_key)

        commit(:post, "application_fees/#{CGI.escape(identification)}/refund", post, options)
      end

      # Note: creating a new credit card will not change the customer's existing default credit card (use :set_default => true)
      def store(payment, options = {})
        card_params = {}
        post = {}

        if payment.is_a?(ApplePayPaymentToken)
          token_exchange_response = tokenize_apple_pay_token(payment)
          card_params = { card: token_exchange_response.params["token"]["id"] } if token_exchange_response.success?
        else
          add_creditcard(card_params, payment, options)
        end

        post[:description] = options[:description] if options[:description]
        post[:email] = options[:email] if options[:email]

        if options[:customer]
          MultiResponse.run(:first) do |r|
            # The /cards endpoint does not update other customer parameters.
            r.process { commit(:post, "customers/#{CGI.escape(options[:customer])}/cards", card_params, options) }

            if options[:set_default] and r.success? and !r.params['id'].blank?
              post[:default_card] = r.params['id']
            end

            if post.count > 0
              r.process { update_customer(options[:customer], post) }
            end
          end
        else
          commit(:post, 'customers', post.merge(card_params), options)
        end
      end

      def update(customer_id, card_id, options = {})
        commit(:post, "customers/#{CGI.escape(customer_id)}/cards/#{CGI.escape(card_id)}", options, options)
      end

      def update_customer(customer_id, options = {})
        commit(:post, "customers/#{CGI.escape(customer_id)}", options, options)
      end

      def unstore(customer_id, options = {}, deprecated_options = {})
        if options.kind_of?(String)
          ActiveMerchant.deprecated "Passing the card_id as the 2nd parameter is deprecated. Put it in the options hash instead."
          options = deprecated_options.merge(card_id: options)
        end

        if options[:card_id]
          commit(:delete, "customers/#{CGI.escape(customer_id)}/cards/#{CGI.escape(options[:card_id])}", nil, options)
        else
          commit(:delete, "customers/#{CGI.escape(customer_id)}", nil, options)
        end
      end

      def tokenize_apple_pay_token(apple_pay_payment_token, options = {})
        token_response = api_request(:post, "tokens?pk_token=#{CGI.escape(apple_pay_payment_token.payment_data.to_json)}")
        success = !token_response.key?("error")

        if success && token_response.key?("id")
          Response.new(success, nil, token: token_response)
        else
          Response.new(success, token_response["error"]["message"])
        end
      end

      def supports_scrubbing?
        true
      end

      def scrub(transcript)
        transcript.
          gsub(%r((Authorization: Basic )\w+), '\1[FILTERED]').
          gsub(%r((card\[number\]=)\d+), '\1[FILTERED]').
          gsub(%r((card\[cvc\]=)\d+), '\1[FILTERED]').
          gsub(%r((&?three_d_secure\[cryptogram\]=)[\w=]*(&?)), '\1[FILTERED]\2')
      end

      private

      class StripePaymentToken < PaymentToken
        def type
          'stripe'
        end
      end

      class StripeICCData
        # Handles Stripe-specific parsing of a raw BER-TLV string.
        attr_reader :number, :track_data, :icc_data, :emv_application_id, :emv_application_label, :emv_verification_method

        def initialize(raw_tlv_string)
          require 'grizzly_ber'
          parsed_tlv = GrizzlyBer.new(raw_tlv_string)

          # Stripe requires the card number and track data to be extracted and removed from the ICC data.
          @number = parsed_tlv.hex_value_of_first_element_with_tag("5A")
          track_data = parsed_tlv.hex_value_of_first_element_with_tag("57")
          @track_data = ";#{track_data.gsub('D', '=')}?"

          # The card number and track data is removed from the ICC data here.
          parsed_tlv.remove!("57")
          parsed_tlv.remove!("5A")

          # A few other parameters are saved out of the ICC Data to be later added to the receipt.
          @emv_application_id =   parsed_tlv.hex_value_of_first_element_with_tag("4F")
          @emv_application_id ||= parsed_tlv.hex_value_of_first_element_with_tag("9F06")
          @emv_application_id ||= parsed_tlv.hex_value_of_first_element_with_tag("84")
          @emv_application_label = parsed_tlv["9F12"] || parsed_tlv["50"]
          @emv_application_label &&= @emv_application_label.pack("C*")
          @emv_verification_method = parsed_tlv["9F34"].first & 0x3F unless parsed_tlv["9F34"].nil? || parsed_tlv["9F34"].length < 1
          @emv_verification_method =
            if parsed_tlv["9F34"] && parsed_tlv["9F34"].length >= 1
              case parsed_tlv["9F34"].first & 0x3F
              when 0x01
                "Offline PIN"
              when 0x02
                "Online PIN"
              when 0x03
                "Offline PIN and Signature"
              when 0x04
                "Offline PIN"
              when 0x05
                "Offline PIN and Signature"
              when 0x1E
                "Signature"
              end
            end
          # Some notes on the verification method:
          #  EMV Book 4 Section 6.3.4.5 and EMV Book 3 Annex C3
          #  The first byte is the method and the second byte is what condition the rule was applied in.
          #  The third byte is whether verfication was successful.
          #  The top two bits of the first byte are RFU and failover instructions so are dropped with the 3F mask.
          #  Valid values are:
          #   01 - Offline PIN (Plaintext)
          #   02 - Online PIN
          #   03 - Offline PIN (Plaintext) and Signature
          #   04 - Offline PIN (Enciphered)
          #   05 - Offline PIN (Enciphered) and Signature
          #   1E - Signature

          @icc_data = parsed_tlv.to_ber
        end
      end

      def create_post_for_auth_or_purchase(money, payment, options)
        post = {}

        if payment.is_a?(StripePaymentToken)
          add_payment_token(post, payment, options)
        else
          add_creditcard(post, payment, options)
        end
        unless payment.respond_to?(:icc_data) && payment.icc_data.present?
          add_amount(post, money, options, true)
          add_customer_data(post, options)
          add_metadata(post, options)
          post[:description] = options[:description]
          post[:statement_description] = options[:statement_description]
          add_customer(post, payment, options)
          add_flags(post, options)
          add_application_fee(post, options)
        end

        post
      end

      def add_amount(post, money, options, include_currency = false)
        currency = options[:currency] || currency(money)
        post[:amount] = localized_amount(money, currency)
        post[:currency] = currency.downcase if include_currency
      end

      def add_application_fee(post, options)
        post[:application_fee] = options[:application_fee] if options[:application_fee]
      end

      def add_expand_parameters(post, options)
        post[:expand] = Array.wrap(options[:expand])
      end

      def add_customer_data(post, options)
        metadata_options = [:description, :ip, :user_agent, :referrer]
        post.update(options.slice(*metadata_options))

        post[:external_id] = options[:order_id]
        post[:payment_user_agent] = "Stripe/v1 ActiveMerchantBindings/#{ActiveMerchant::VERSION}"
      end

      def add_address(post, options)
        return unless post[:card] && post[:card].kind_of?(Hash)
        if address = options[:billing_address] || options[:address]
          post[:card][:address_line1] = address[:address1] if address[:address1]
          post[:card][:address_line2] = address[:address2] if address[:address2]
          post[:card][:address_country] = address[:country] if address[:country]
          post[:card][:address_zip] = address[:zip] if address[:zip]
          post[:card][:address_state] = address[:state] if address[:state]
          post[:card][:address_city] = address[:city] if address[:city]
        end
      end

      def add_creditcard(post, creditcard, options)
        card = {}
        if creditcard.respond_to?(:icc_data) && creditcard.icc_data.present?
          emv_credit_card = StripeICCData.new(creditcard.icc_data)
          @emv_receipt = {
            :emv_application_id => emv_credit_card.emv_application_id,
            :emv_application_label => emv_credit_card.emv_application_label,
            :emv_verification_method => emv_credit_card.emv_verification_method
          }
          card[:number] = emv_credit_card.number
          card[:swipe_data] = emv_credit_card.track_data
          card[:icc_data] = emv_credit_card.icc_data
          post[:card] = card
        elsif creditcard.respond_to?(:number)
          if creditcard.respond_to?(:track_data) && creditcard.track_data.present?
            card[:swipe_data] = creditcard.track_data
          else
            card[:number] = creditcard.number
            card[:exp_month] = creditcard.month
            card[:exp_year] = creditcard.year
            card[:cvc] = creditcard.verification_value if creditcard.verification_value?
            card[:name] = creditcard.name if creditcard.name
          end
          post[:card] = card

          if creditcard.is_a?(NetworkTokenizationCreditCard)
            post[:three_d_secure] = {
              apple_pay:  true,
              cryptogram: creditcard.payment_cryptogram
            }
          end

          add_address(post, options)
        elsif creditcard.kind_of?(String)
          if options[:track_data]
            card[:swipe_data] = options[:track_data]
          else
            card = creditcard
          end
          post[:card] = card
        end
      end

      def add_payment_token(post, token, options = {})
        post[:card] = token.payment_data["id"]
      end

      def add_customer(post, payment, options)
        post[:customer] = options[:customer] if options[:customer] && !payment.respond_to?(:number)
      end

      def add_flags(post, options)
        post[:uncaptured] = true if options[:uncaptured]
        post[:recurring] = true if (options[:eci] == 'recurring' || options[:recurring])
      end

      def add_metadata(post, options = {})
        post[:metadata] = {}
        post[:metadata][:email] = options[:email] if options[:email]
        post[:metadata][:order_id] = options[:order_id] if options[:order_id]
        post.delete(:metadata) if post[:metadata].empty?
      end

      def fetch_application_fees(identification, options = {})
        options.merge!(:key => @fee_refund_api_key)

        commit(:get, "application_fees?charge=#{identification}", nil, options)
      end

      def parse(body)
        JSON.parse(body)
      end

      def post_data(params)
        return nil unless params

        params.map do |key, value|
          next if value.blank?
          if value.is_a?(Hash)
            h = {}
            value.each do |k, v|
              h["#{key}[#{k}]"] = v unless v.blank?
            end
            post_data(h)
          elsif value.is_a?(Array)
            value.map { |v| "#{key}[]=#{CGI.escape(v.to_s)}" }.join("&")
          else
            "#{key}=#{CGI.escape(value.to_s)}"
          end
        end.compact.join("&")
      end

      def headers(options = {})
        key     = options[:key] || @api_key
        version = options[:version] || @version

        headers = {
          "Authorization" => "Basic " + Base64.encode64(key.to_s + ":").strip,
          "User-Agent" => "Stripe/v1 ActiveMerchantBindings/#{ActiveMerchant::VERSION}",
          "X-Stripe-Client-User-Agent" => user_agent,
          "X-Stripe-Client-User-Metadata" => {:ip => options[:ip]}.to_json
        }
        headers.merge!("Stripe-Version" => version) if version
        headers
      end

      def api_request(method, endpoint, parameters = nil, options = {})
        raw_response = response = nil
        begin
          raw_response = ssl_request(method, self.live_url + endpoint, post_data(parameters), headers(options))
          response = parse(raw_response)
        rescue ResponseError => e
          raw_response = e.response.body
          response = response_error(raw_response)
        rescue JSON::ParserError
          response = json_error(raw_response)
        end
        response
      end

      def commit(method, url, parameters = nil, options = {})
        add_expand_parameters(parameters, options) if parameters

        response = api_request(method, url, parameters, options)
        success = !response.key?("error")

        response.merge! @emv_receipt if @emv_receipt
        card = response["card"] || response["active_card"] || {}
        avs_code = AVS_CODE_TRANSLATOR["line1: #{card["address_line1_check"]}, zip: #{card["address_zip_check"]}"]
        cvc_code = CVC_CODE_TRANSLATOR[card["cvc_check"]]

        Response.new(success,
          success ? "Transaction approved" : response["error"]["message"],
          response,
          :test => response.has_key?("livemode") ? !response["livemode"] : false,
          :authorization => success ? response["id"] : response["error"]["charge"],
          :avs_result => { :code => avs_code },
          :cvv_result => cvc_code,
          :emv_authorization => card["icc_data"],
          :error_code => success ? nil : STANDARD_ERROR_CODE_MAPPING[response["error"]["code"]]
        )
      end

      def response_error(raw_response)
        begin
          parse(raw_response)
        rescue JSON::ParserError
          json_error(raw_response)
        end
      end

      def json_error(raw_response)
        msg = 'Invalid response received from the Stripe API.  Please contact support@stripe.com if you continue to receive this message.'
        msg += "  (The raw response returned by the API was #{raw_response.inspect})"
        {
          "error" => {
            "message" => msg
          }
        }
      end

      def non_fractional_currency?(currency)
        CURRENCIES_WITHOUT_FRACTIONS.include?(currency.to_s)
      end
    end
  end
end
