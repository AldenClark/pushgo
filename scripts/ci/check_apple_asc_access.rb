#!/usr/bin/env ruby
# Read-only ASC qualification. Keys, tokens and response bodies stay in memory.
require 'base64'
require 'json'
require 'net/http'
require 'openssl'
require 'fileutils'
require 'uri'

module AppleASCAccess
  HOST = 'api.appstoreconnect.apple.com'.freeze
  # Automatically retrieved/generated profile targets in apple-release.yml.
  BUNDLES = %w[io.ethan.pushgo io.ethan.pushgo.NotificationServiceExtension
               io.ethan.pushgo.watchkitapp io.ethan.pushgo.watchkitapp.NotificationServiceExtension
               io.ethan.pushgo.macwidgets].freeze

  def self.encode(value)
    Base64.urlsafe_encode64(value, padding: false)
  end

  def self.token(environment, now)
    raw = environment.fetch('ASC_KEY_P8')
    raw = Base64.strict_decode64(raw) if environment['ASC_KEY_IS_BASE64'] == 'true'
    key = OpenSSL::PKey.read(raw)
    raise 'unsupported_key' unless key.is_a?(OpenSSL::PKey::EC) && key.group.curve_name == 'prime256v1'
    header = {alg: 'ES256', kid: environment.fetch('ASC_KEY_ID'), typ: 'JWT'}
    payload = {iss: environment.fetch('ASC_ISSUER_ID'), iat: now, exp: now + 300, aud: 'appstoreconnect-v1'}
    unsigned = [encode(JSON.generate(header)), encode(JSON.generate(payload))].join('.')
    components = OpenSSL::ASN1.decode(key.sign('SHA256', unsigned)).value
    raise 'invalid_signature' unless components.length == 2
    signature = components.map do |component|
      bytes = component.value.to_s(2)
      raise 'invalid_signature' if bytes.bytesize > 32
      bytes.rjust(32, "\0")
    end.join
    unsigned + '.' + encode(signature)
  end

  def self.get(path, parameters, bearer)
    uri = URI::HTTPS.build(host: HOST, path: path, query: URI.encode_www_form(parameters))
    http = Net::HTTP.new(HOST, 443, nil)
    http.use_ssl = true
    http.open_timeout = 10
    http.read_timeout = 10
    request = Net::HTTP::Get.new(uri.request_uri)
    request['Authorization'] = 'Bearer ' + bearer
    request['Accept'] = 'application/json'
    response = http.request(request)
    return [response.code.to_i, nil] unless response.code == '200'
    raise 'response_too_large' if response.body.bytesize > 1_048_576
    [200, JSON.parse(response.body)]
  end

  def self.check(environment, transport: method(:get), now: Time.now.to_i)
    report = {schema_version: 1, source_revision: environment['GITHUB_SHA'], status: 'BLOCKED',
              checks: {}, actual_signing: 'NOT_RUN', publication: 'NOT_RUN',
              limitations: ['GET access only; no upload or profile-creation permission claim',
                            'No profile installation, credential-store writes or signed build']}
    begin
      bearer = token(environment, now)
      report[:checks][:key_decoded_and_token_signed] = true
      code, body = transport.call('/v1/bundleIds', {'filter[identifier]' => BUNDLES.join(','), 'fields[bundleIds]' => 'identifier', 'limit' => '20'}, bearer)
      report[:checks][:bundle_ids_readable] = code == 200 && body.is_a?(Hash) && body['data'].is_a?(Array)
      identifiers = report[:checks][:bundle_ids_readable] ? body['data'].map { |row| row.fetch('attributes', {})['identifier'] } : []
      report[:checks][:required_bundle_ids_present] = BUNDLES.all? { |bundle| identifiers.count(bundle) == 1 }
      code, body = transport.call('/v1/profiles', {'fields[profiles]' => 'profileType', 'limit' => '1'}, bearer)
      report[:checks][:profiles_readable] = code == 200 && body.is_a?(Hash) && body['data'].is_a?(Array)
      code, body = transport.call('/v1/apps', {'filter[bundleId]' => 'io.ethan.pushgo', 'fields[apps]' => 'bundleId', 'limit' => '2'}, bearer)
      report[:checks][:app_record_readable] = code == 200 && body.is_a?(Hash) && body['data'].is_a?(Array)
      report[:checks][:app_record_matches] = report[:checks][:app_record_readable] && body['data'].count { |row| row.fetch('attributes', {})['bundleId'] == 'io.ethan.pushgo' } == 1
      report[:status] = 'PASSED' if report[:checks].values.all?
    rescue StandardError
      # Do not serialize exception messages, HTTP bodies, identifiers or tokens.
      report[:checks][:completed_without_decoder_or_transport_error] = false
    end
    report
  end
end

if __FILE__ == $PROGRAM_NAME
  report = AppleASCAccess.check(ENV)
  output = ARGV.fetch(0)
  FileUtils.mkdir_p(File.dirname(output))
  File.write(output, JSON.pretty_generate(report) + "\n")
  puts JSON.generate(report)
  exit(report[:status] == 'PASSED' ? 0 : 2)
end
