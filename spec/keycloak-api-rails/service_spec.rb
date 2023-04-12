RSpec.describe Keycloak::Service do

  let!(:private_key)  { OpenSSL::PKey::RSA.generate(2048) }
  let!(:public_key)   { private_key.public_key }
  let!(:key_resolver)  { Keycloak::PublicKeyCachedResolverStub.new(public_key) }
  let!(:service)       { Keycloak::Service.new(key_resolver) }
  
  before(:each) do
    now = Time.local(2018, 1, 9, 12, 0, 0)
    Timecop.freeze(now)
  end

  after(:each) do
    Timecop.return
  end

  describe "#decode_and_verify" do
    def create_token(private_key, expiration_date, algorithm)
      claim = {
        iss: "Keycloak",
        exp: expiration_date,
        nbf: Time.local(2018, 1, 1, 0, 0, 0)
      }
      jws = JSON::JWT.new(claim).sign(private_key, algorithm)
      jws.to_s
    end

    context "when token is nil" do
      let(:token) { nil }
      it "should raise an error :no_token" do
        expect {
          service.decode_and_verify(token)
        }.to raise_error(TokenError, "No JWT token provided")
      end
    end

    context "when token is an empty string" do
      let(:token) { "" }
      it "should raise an error :no_token" do
        expect {
          service.decode_and_verify(token)
        }.to raise_error(TokenError, "No JWT token provided")
      end
    end

    context "when token is in an invalid format" do
      let(:token) { "coucou" }
      it "should raise an error :invalid_format" do
        expect {
          service.decode_and_verify(token)
        }.to raise_error(TokenError, "Wrong JWT Format")
      end
    end

    context "when token is in a valid format" do
      let(:algorithm)       { :RS256 }
      let(:expiration_date) { 1.week.from_now }

      context "and token is generated by another private key" do
        let(:another_private_key)  { OpenSSL::PKey::RSA.generate(1024) }
        let(:token)                { create_token(another_private_key, expiration_date, algorithm) }
        
        it "should raise an error :verification_failed" do
          expect {
            service.decode_and_verify(token)
          }.to raise_error(TokenError, "Failed to verify JWT token")
        end
      end

      context "and token is generated by the right private key" do
        let(:token) { create_token(private_key, expiration_date, algorithm) }
        
        context "and token is expired" do
          let(:expiration_date) { Time.now - 2.days }
          
          it "should raise an error :expiration_date" do
            expect {
              service.decode_and_verify(token)
            }.to raise_error(TokenError, "JWT token is expired")
          end
        end

        context "and token is not expired" do
          let(:expiration_date) { Time.now + 2.days }
          
          context "and token is encrypted using RS256" do
            let(:algorithm) { :RS256 }
            
            it "should return a not-nil decoded token" do
              expect(service.decode_and_verify(token)).to_not be_nil
            end
          end

          context "and token is encrypted using RS512" do
            let(:algorithm) { :RS512 }
            
            it "should return a not-nil decoded token" do
              expect(service.decode_and_verify(token)).to_not be_nil
            end
          end
        end
      end
    end
  end

  describe "#need_middleware_authentication?" do

    let(:method)  { nil }
    let(:path)    { nil }
    let(:headers) { {} }


    before(:each) do
      Keycloak.config.skip_paths = {
        post:   [/^\/skip/],
        get:    [/^\/skip/]
      }
      @result = service.need_middleware_authentication?(method, path, headers)
    end

    context "when method is nil" do
      let(:method) { nil }
      let(:path)   { "/do-not-skip" }
      it "should return true" do
        expect(@result).to be true
      end
    end

    context "when path is nil" do
      let(:method) { :get }
      let(:path)   { nil }
      it "should return true" do
        expect(@result).to be true
      end
    end

    context "when method does not match the configuration" do
      let(:method) { :put }
      let(:path)   { "/skip" }
      it "should return true" do
        expect(@result).to be true
      end
    end

    context "when path does not match the configuration" do
      let(:method) { :get }
      let(:path)   { "/do-not-skip" }
      it "should return true" do
        expect(@result).to be true
      end
    end

    context "when method [get] and path do match the configuration" do
      let(:method) { :get }
      let(:path)   { "/skip" }
      it "should return false" do
        expect(@result).to be false
      end
    end


    context "when method [post] and path do match the configuration" do
      let(:method) { :get }
      let(:path)   { "/skip" }
      it "should return false" do
        expect(@result).to be false
      end
    end

    context "when the request is preflight" do
      let(:method)  { :options }
      let(:headers) { { "HTTP_ACCESS_CONTROL_REQUEST_METHOD" => ["Authorization"] } }
      let(:path)    { "/do-not-skip" }
      it "should return false" do
        expect(@result).to be false
      end
    end

    context "when configured as opt_in" do
      before do
        Keycloak.config.opt_in = true
        service2 = Keycloak::Service.new(key_resolver)
        @result = service2.need_middleware_authentication?(method, path, headers)
      end

      it "should return false" do
        expect(@result).to be false
      end
    end
  end

  describe "#read_token" do
    let(:query_string)       { "" }
    let(:url)                { "http://api.service.com/api/health?aParameter=true#{query_string}" }
    let(:headers)            { {} }
    let(:header_token)       { "header_token" }
    let(:query_string_token) { "query_string_token" }

    before(:each) do
      @token = service.read_token(url, headers)
    end

    context "when the token is provided in the Authorization headers" do
      let(:headers) do
        {
          "HTTP_AUTHORIZATION" => "Bearer #{header_token}"
        }
      end
      context "and not in the query string" do
        let(:query_string) { "" }
        it "returns the header token" do
          expect(@token).to eq header_token
        end
      end

      context "and also in the query string" do
        let(:query_string) { "&authorizationToken=#{query_string_token}" }
        it "returns the query string token" do
          expect(@token).to eq query_string_token
        end
      end
    end

    context "when the token is not provided in the Authorization headers" do
      let(:headers) do
        {
          "ANOTHER_HEADER" => header_token
        }
      end

      context "and not in the query string" do
        let(:query_string) { "" }
        it "returns an empty token" do
          expect(@token).to eq ""
        end
      end

      context "and query string is nil" do
        let(:query_string) { nil }
        it "returns an empty token" do
          expect(@token).to eq ""
        end
      end

      context "but in the query string" do
        let(:query_string) { "&authorizationToken=#{query_string_token}" }
        it "returns the query string token" do
          expect(@token).to eq query_string_token
        end
      end
    end
  end
end