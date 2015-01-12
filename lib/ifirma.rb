require 'openssl'
require 'faraday'
require 'faraday_middleware'
require 'yajl'

require 'ifirma/version'
require 'ifirma/auth_middleware'
require 'ifirma/response'

class Ifirma
  def initialize(options = {})
    configure(options)
  end

  def configure(options)
    raise "Please provide config data" unless options[:config]

    @invoices_key = options[:config][:invoices_key]
    @username     = options[:config][:username]
  end

  [:get, :post, :put, :delete, :head].each do |method|
    define_method(method) do |*args, &block|
      connection.send(method, *args, &block)
    end
  end

  def create_invoice(attrs, proforma = false)
    invoice_json = normalize_attributes_for_request(attrs)
    if proforma
      response = post("/iapi/fakturaproformakraj.json", invoice_json)
    else
      response = post("/iapi/fakturakraj.json", invoice_json)
    end

    Response.new(response.body["response"])
  end

  def create_invoice_proforma(attrs)
    create_invoice(attrs, true)
  end

  def get_invoice(invoice_id, type = 'pdf')
    json_invoice = get("/iapi/fakturakraj/#{invoice_id}.json")
    response = Response.new(json_invoice.body["response"])
    if response.success?
      response = get("/iapi/fakturakraj/#{invoice_id}.#{type}")
      response = Response.new(response.body)
    end
    response
  end

  def get_invoices
    json_invoice = get("/iapi/fakturakraj/list.json?limit=10")
    response = Response.new(json_invoice.body["response"])
    # if response.success?
    #   response = get("/iapi/fakturakraj/#{invoice_id}.#{type}")
    #   response = Response.new(response.body)
    # end
    response
  end

  ATTRIBUTES_MAP = {
    :paid             => "Zaplacono",
    :paid_on_document => "ZaplaconoNaDokumencie",
    :type             => "LiczOd",
    :account_no       => "NumerKontaBankowego",
    :issue_date       => "DataWystawienia",
    :issue_city       => "MiejsceWystawienia",
    :sale_date        => "DataSprzedazy",
    :sale_date_format => "FormatDatySprzedazy",
    :due_date         => "TerminPlatnosci",
    :payment_type     => "SposobZaplaty",
    :serial_name      => "NazwaSeriiNumeracji",
    :template_name    => "NazwaSzablonu",
    :designation_type => "RodzajPodpisuOdbiorcy",
    :customer_signature => "PodpisOdbiorcy",
    :issuer_signature => "PodpisWystawcy",
    :comments         => "Uwagi",
    :gios             => "WidocznyNumerGios",
    :number           => "Numer",
    :customer_id      => "IdentyfikatorKontrahenta",
    :customer_eu_preffix => "PrefiksUEKontrahenta",
    :customer_nip     => "NIPKontrahenta",
    :issue_address    => "MiejsceWystawienia",
    :invoice_type     => "TypFakturyKrajowej",
    :order_number     => "NumerZamowienia",
    :customer         => {
      :id       => 'Identyfikator',
      :customer => "Kontrahent",
      :name     => "Nazwa",
      :name2    => "Nazwa2",
      :eu_preffix => "PrefiksUE",
      :nip      => "NIP",
      :street   => "Ulica",
      :zipcode  => "KodPocztowy",
      :city     => "Miejscowosc",
      :country  => "Kraj",
      :email    => "Email",
      :phone    => "Telefon",
      :phisical_person => "OsobaFizyczna",
      :is_customer => "JestOdbiorca",
      :is_supplier => "JestDostawca"
    },
    :items => {
      :items    => "Pozycje",
      :vat_rate => "StawkaVat",
      :quantity => "Ilosc",
      :price    => "CenaJednostkowa",
      :name     => "NazwaPelna",
      :unit     => "Jednostka",
      :pkwiu    => "PKWiU",
      :vat_type => "TypStawkiVat",
      :discount => "Rabat"
    }
  }

  DATE_MAPPER = lambda { |value| value.strftime("%Y-%m-%d") }

  VALUE_MAP = {
    :issue_date => DATE_MAPPER,
    :sale_date  => DATE_MAPPER,
    :due_date   => DATE_MAPPER,
    :account_no => lambda { |value| value != nil ? value.tr(" ", "") : value },
    :type => {
      :net   => "NET",
      :gross => "BRT"
    },
    :invoice_type => {
      :country    => "SPRZ",
      :building   => "BUD",
      :imprest    => "ZAL"
    },
    :payment_type => {
      :wire        => "PRZ",
      :cash        => "GTK",
      :offset      => "KOM",
      :on_delivery => "POB",
      :dotpay      => "DOT",
      :paypal      => "PAL",
      :electronic  => "ELE",
      :card        => "KAR",
      :payu        => "ALG",
      :cheque      => "CZK"
    },
    :sale_date_format => {
      :daily   => "DZN",
      :monthly => "MSC"
    },
    :items => {
      :vat_type => {
        :percent => "PRC",
        :exempt  => "ZW"
      },
      :vat_rate => lambda { |value| (value.to_f / 100).to_s },
    }
  }

private

  def normalize_attributes_for_request(attrs, result = {}, map = ATTRIBUTES_MAP, value_map = VALUE_MAP)
    attrs.each do |key, value|
      if value.is_a? Array
        nested_key = map[key][key]
        result[nested_key] = []
        value.each do |item|
          result[nested_key] << normalize_attributes_for_request(item, {}, map[key], value_map[key] || {})
        end
      elsif value.is_a? Hash
        nested_key = map[key][key]
        result[nested_key] = {}
        normalize_attributes_for_request(attrs[key], result[nested_key], map[key], value_map[key] || {})
      else
        translated = map[key]
        result[translated] = normalize_attribute(value, value_map[key])
      end
    end

    result
  end

  def normalize_attribute(value, mapper)
    return value unless mapper
    if mapper.respond_to?(:call)
      mapper.call(value)
    else
      mapper[value]
    end
  end

  def connection
    @connection ||= begin
      Faraday.new 'https://www.ifirma.pl/' do |builder|
        builder.use FaradayMiddleware::ParseJson, :content_type => 'application/json'
        builder.use Faraday::Request::UrlEncoded
        builder.use FaradayMiddleware::EncodeJson
        builder.use Ifirma::AuthMiddleware, :username => @username, :invoices_key => @invoices_key
#        builder.use Faraday::Response::Logger
        builder.use Faraday::Adapter::NetHttp
      end.tap do |connection|
        connection.headers["Content-Type"] = "application/json; charset=utf-8"
        connection.headers["Accept"]       = "application/json"

      end
    end
  end
end
