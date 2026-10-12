require 'minitest/autorun'
require_relative '../ci/check_apple_asc_access'

class AppleASCAccessTests < Minitest::Test
  def setup
    @key = OpenSSL::PKey::EC.generate('prime256v1')
    @environment = {'ASC_KEY_P8' => @key.to_pem, 'ASC_KEY_ID' => 'FIXTURE_KEY', 'ASC_ISSUER_ID' => 'FIXTURE_ISSUER'}
  end

  def response(path, _parameters, _bearer)
    case path
    when '/v1/bundleIds'
      [200, {'data' => AppleASCAccess::BUNDLES.map { |bundle| {'attributes' => {'identifier' => bundle}} }}]
    when '/v1/apps'
      [200, {'data' => [{'attributes' => {'bundleId' => 'io.ethan.pushgo'}}]}]
    when '/v1/profiles'
      [200, {'data' => []}]
    else
      flunk('Unexpected endpoint')
    end
  end

  def test_signed_token_has_correct_signature_audience_and_short_expiry
    token = AppleASCAccess.token(@environment, 1000)
    header, payload, signature = token.split('.')
    claims = JSON.parse(Base64.urlsafe_decode64(payload))
    assert_equal 1300, claims['exp']
    assert_equal 'appstoreconnect-v1', claims['aud']
    bytes = Base64.urlsafe_decode64(signature)
    assert_equal 64, bytes.bytesize
    integers = [bytes[0, 32], bytes[32, 32]].map { |part| OpenSSL::ASN1::Integer.new(OpenSSL::BN.new(part, 2)) }
    assert @key.verify('SHA256', OpenSSL::ASN1::Sequence.new(integers).to_der, [header, payload].join('.'))
    encoded = @environment.merge('ASC_KEY_P8' => Base64.strict_encode64(@key.to_pem), 'ASC_KEY_IS_BASE64' => 'true')
    assert_equal 3, AppleASCAccess.token(encoded, 1000).split('.').length
  end

  def test_read_access_does_not_claim_creation_upload_or_actual_signing
    result = AppleASCAccess.check(@environment, transport: method(:response))
    assert_equal 'PASSED', result[:status]
    assert_equal 'NOT_RUN', result[:actual_signing]
    assert_equal 'NOT_RUN', result[:publication]
  end

  def test_missing_bundle_or_forbidden_api_cannot_pass
    forbidden = ->(path, parameters, bearer) { path == '/v1/profiles' ? [403, nil] : response(path, parameters, bearer) }
    assert_equal 'BLOCKED', AppleASCAccess.check(@environment, transport: forbidden)[:status]
    missing = ->(path, parameters, bearer) { path == '/v1/bundleIds' ? [200, {'data' => []}] : response(path, parameters, bearer) }
    assert_equal 'BLOCKED', AppleASCAccess.check(@environment, transport: missing)[:status]
  end

  def test_errors_export_no_private_key_token_or_exception_text
    leaking_error = ->(*) { raise 'PRIVATE_SENTINEL' }
    result = JSON.generate(AppleASCAccess.check(@environment, transport: leaking_error))
    refute_includes result, 'PRIVATE_SENTINEL'
    refute_includes result, @key.to_pem
    refute_includes result, 'FIXTURE_KEY'
    refute_includes result, 'FIXTURE_ISSUER'
  end
end
