require "zanzibar/version"
require 'savon'
require 'io/console'
require 'fileutils'

module Zanzibar

  ##
  # Class for interacting with Secret Server
  class Zanzibar

    ##
    # @param args{:domain, :wsdl, :pwd, :username, :globals{}}

    def initialize(args = {})

      if args[:username]
        @@username = args[:username]
      else
        @@username = ENV['USER']
      end

      if args[:wsdl]
        @@wsdl = args[:wsdl]
      else
        @@wsdl = get_wsdl_location
      end
      if args[:pwd]
          @@password = args[:pwd]
      else
        @@password = prompt_for_password
      end
      if args[:domain]
        @@domain = args[:domain]
      else
        @@domain = prompt_for_domain
      end
      args[:globals] = {} unless args[:globals]
      init_client(args[:globals])
    end

    ## Initializes the Savon client class variable with the wdsl document location and optional global variables
    # @param globals{}, optional

    def init_client(globals = {})
      globals = {} if globals == nil
      @@client = Savon.client(globals) do
        wsdl @@wsdl
      end
    end

    ## Gets the user's password if none is provided in the constructor.
    # @return [String] the password for the current user

    def prompt_for_password
      puts "Please enter password for #{@@username}:"
      return STDIN.noecho(&:gets).chomp
    end

    ## Gets the wsdl document location if none is provided in the constructor
    # @return [String] the location of the WDSL document

    def get_wsdl_location
      puts "Enter the URL of the Secret Server WSDL:"
      return STDIN.gets.chomp
    end

    ## Gets the domain of the Secret Server installation if none is provided in the constructor
    # @return [String] the domain of the secret server installation

    def prompt_for_domain
      puts "Enter the domain of your Secret Server:"
      return STDIN.gets.chomp
    end


    ## Get an authentication token for interacting with Secret Server. These are only good for about 10 minutes so just get a new one each time.
    # Will raise an error if there is an issue with the authentication.
    # @return the authentication token for the current user.

    def get_token
      begin
        response = @@client.call(:authenticate, message: { username: @@username, password: @@password, organization: "", domain: @@domain }).hash
        if response[:envelope][:body][:authenticate_response][:authenticate_result][:errors]
          raise "Error generating the authentication token for user #{@@username}: #{response[:envelope][:body][:authenticate_response][:authenticate_result][:errors][:string]}"
        end
        response[:envelope][:body][:authenticate_response][:authenticate_result][:token]
      rescue Savon::Error => err
        raise "There was an error generating the authentiaton token for user #{@@username}: #{err}"
      end
    end

    ## Get a secret returned as a hash
    # Will raise an error if there was an issue getting the secret
    # @param [Integer] the secret id
    # @return [Hash] the secret hash retrieved from the wsdl

    def get_secret(scrt_id, token = nil)
      begin
        secret = @@client.call(:get_secret, message: { token: token || get_token, secretId: scrt_id}).hash
        if secret[:envelope][:body][:get_secret_response][:get_secret_result][:errors]
          raise "There was an error getting secret #{scrt_id}: #{secret[:envelope][:body][:get_secret_response][:get_secret_result][:errors][:string]}"
        end
        return secret
      rescue Savon::Error => err
        raise "There was an error getting the secret with id #{scrt_id}: #{err}"
      end
    end

    ## Retrieve a simple password from a secret
    # Will raise an error if there are any issues
    # @param [Integer] the secret id
    # @return [String] the password for the given secret

    def get_password(scrt_id)
      begin
        secret = get_secret(scrt_id)
        secret_items = secret[:envelope][:body][:get_secret_response][:get_secret_result][:secret][:items][:secret_item]
        return get_secret_item_by_field_name(secret_items,"Password")[:value]
      rescue Savon::Error => err
        raise "There was an error getting the password for secret #{scrt_id}: #{err}"
      end
    end

    def get_secret_item_by_field_name(secret_items, field_name)
      secret_items.each do |item|
        return item if item[:field_name] == field_name
      end
    end

    ## Get the secret item id that relates to a key file or attachment.
    # Will raise on error
    # @param [Integer] the secret id
    # @param [String] the type of secret item to get, one of privatekey, publickey, attachment
    # @return [Integer] the secret item id

    def get_scrt_item_id(scrt_id, type, token)
      secret = get_secret(scrt_id, token)
      secret_items = secret[:envelope][:body][:get_secret_response][:get_secret_result][:secret][:items][:secret_item]
      begin
        return get_secret_item_by_field_name(secret_items, type)[:id]
      rescue
        raise "Unknown type, #{type}."
      end
    end

    ## Downloads the private key for a secret and places it where Zanzibar is running, or :path if specified
    # Raise on error
    # @param [Hash] args, :scrt_id, :scrt_item_id - optional, :path - optional

    def download_private_key(args = {})
      token = get_token
      FileUtils.mkdir_p(args[:path]) if args[:path]
      path = args[:path] ? args[:path] : '.' ## The File.join below doesn't handle nils well, so let's take that possibility away.
      begin
        response = @@client.call(:download_file_attachment_by_item_id, message: { token: token, secretId: args[:scrt_id], secretItemId: args[:scrt_item_id] || get_scrt_item_id(args[:scrt_id], 'Private Key', token)}).hash
        if response[:envelope][:body][:download_file_attachment_by_item_id_response][:download_file_attachment_by_item_id_result][:errors]
          raise "There was an error getting the private key for secret #{args[:scrt_id]}: #{response[:envelope][:body][:download_file_attachment_by_item_id_response][:download_file_attachment_by_item_id_result][:string]}"
        end
        File.open(File.join(path, response[:envelope][:body][:download_file_attachment_by_item_id_response][:download_file_attachment_by_item_id_result][:file_name]), 'wb') do |file|
          file.puts Base64.decode64(response[:envelope][:body][:download_file_attachment_by_item_id_response][:download_file_attachment_by_item_id_result][:file_attachment])
        end
      rescue Savon::Error => err
        raise "There was an error getting the private key for secret #{args[:scrt_id]}: #{err}"
      end
    end

    ## Downloads the public key for a secret and places it where Zanzibar is running, or :path if specified
    # Raise on error
    # @param [Hash] args, :scrt_id, :scrt_item_id - optional, :path - optional

    def download_public_key(args = {})
      token = get_token
      FileUtils.mkdir_p(args[:path]) if args[:path]
      path = args[:path] ? args[:path] : '.' ## The File.join below doesn't handle nils well, so let's take that possibility away.
      begin
        response = @@client.call(:download_file_attachment_by_item_id, message: { token: token, secretId: args[:scrt_id], secretItemId: args[:scrt_item_id] || get_scrt_item_id(args[:scrt_id], 'Public Key', token)}).hash
        if response[:envelope][:body][:download_file_attachment_by_item_id_response][:download_file_attachment_by_item_id_result][:errors]
          raise "There was an error getting the public key for secret #{args[:scrt_id]}: #{response[:envelope][:body][:download_file_attachment_by_item_id_response][:download_file_attachment_by_item_id_result][:string]}"
      end
        File.open(File.join(path, response[:envelope][:body][:download_file_attachment_by_item_id_response][:download_file_attachment_by_item_id_result][:file_name]), 'wb') do |file|
          file.puts Base64.decode64(response[:envelope][:body][:download_file_attachment_by_item_id_response][:download_file_attachment_by_item_id_result][:file_attachment])
        end
      rescue Savon::Error => err
        raise "There was an error getting the public key for secret #{args[:scrt_id]}: #{err}"
      end
    end

    ## Downloads an attachment for a secret and places it where Zanzibar is running, or :path if specified
    # Raise on error
    # @param [Hash] args, :scrt_id, :scrt_item_id - optional, :path - optional

    def download_attachment(args = {})
      token = get_token
      FileUtils.mkdir_p(args[:path]) if args[:path]
      path = args[:path] ? args[:path] : '.' ## The File.join below doesn't handle nils well, so let's take that possibility away.
      begin
        response = @@client.call(:download_file_attachment_by_item_id, message: { token: token, secretId: args[:scrt_id], secretItemId: args[:scrt_item_id] || get_scrt_item_id(args[:scrt_id], 'Attachment', token)}).hash
        if response[:envelope][:body][:download_file_attachment_by_item_id_response][:download_file_attachment_by_item_id_result][:errors]
          raise "There was an error getting the attachment for secret #{args[:scrt_id]}: #{response[:envelope][:body][:download_file_attachment_by_item_id_response][:download_file_attachment_by_item_id_result][:string]}"
      end
        File.open(File.join(path, response[:envelope][:body][:download_file_attachment_by_item_id_response][:download_file_attachment_by_item_id_result][:file_name]), 'wb') do |file|
          file.puts Base64.decode64(response[:envelope][:body][:download_file_attachment_by_item_id_response][:download_file_attachment_by_item_id_result][:file_attachment])
        end
      rescue Savon::Error => err
        raise "There was an error getting the attachment from secret #{args[:scrt_id]}: #{err}"
      end
    end
  end
end
