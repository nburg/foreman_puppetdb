#!/usr/bin/env ruby

# Settings
puppetdb_url = 'http://puppet.example.com:8080'
foreman_url  = 'https://foreman.example.com'
foreman_user = 'admin'
foreman_pass = 'password'

# Handy Class for pushing facts and hosts from puppetdb to foreman through
# their respective web apis.
class FactPush
  require 'rubygems'
  require 'curb'
  require 'json'

  attr_accessor :puppetdb_url,
                :foreman_url,
                :foreman_user,
                :foreman_pass,
                :puppetdb_hosts,
                :foremna_hosts,
                :hosts_delta

  def initialize(puppetdb_url,
                 foreman_url,
                 foreman_user,
                 foreman_pass,
                 puppetdir = '/var/lib/puppet')
    @puppetdb_url     = puppetdb_url
    @foreman_url      = foreman_url
    @foreman_user     = foreman_user
    @foreman_pass     = foreman_pass
    @puppetdir        = puppetdir
    @use_puppet_certs = @puppetdb_url =~ /^https:/ ? true : false
  end

  # Take puppetdb style json hash and convert to something we can send to foreman.
  def squash_facts(host, server_facts)
    facts_hash = {}
    facts_hash['name'] = host
    facts_hash['certname'] = host
    facts_hash['facts'] = {}
    server_facts.each do |fact|
      facts_hash['facts'][fact['name']] = fact['value']
    end
    facts_hash.to_json
  end

  # Pull facts from puppetdb for a single server.
  def get_facts(host)
    curl = setup_curl("#{@puppetdb_url}/v3/nodes/#{host}/facts")
    curl.get
    result = JSON.parse(curl.body_str)
    warn "Error #{host} not found in puppetdb" if result.empty?
    result
  end

  # Get a list of hosts from puppetdb.
  def get_puppetdb_hosts
    curl = setup_curl("#{@puppetdb_url}/v3/nodes")
    curl.get
    servers_junk = JSON.parse(curl.body_str)
    servers_array = []
    servers_junk.each { |server| servers_array << server['name'] }
    @puppetdb_hosts = servers_array
  end

  # Get a list of hosts from foreman.
  def get_foreman_hosts(per_page = 10000)
    curl = setup_curl("#{@foreman_url}/api/hosts?per_page=#{per_page}", true)
    curl.perform
    servers_junk = JSON.parse(curl.body_str)
    servers_array = []
    servers_junk.each { |server| servers_array << server['host']['name'] }
    @foreman_hosts = servers_array
  end

  # Get a list of hosts that are in foreman but not puppetdb.
  def hosts_delta(puppetdb_hosts = @puppetdb_hosts, foreman_hosts = @foreman_hosts)
    @hosts_delta = foreman_hosts - puppetdb_hosts
  end

  # Raps a loop around host_delete for array iteration goodness.
  def host_delete_all(hosts = @hosts_delta)
    hosts.each do |host|
      host_delete(host)
      unmanage_host(host)
    end
  end

  # Deletes a host from foreman
  def host_delete(host)
    curl = setup_curl("#{@foreman_url}/api/hosts/#{host}", true)
    curl.http_delete
  end

  # This keeps foreman from deleting VMs
  def unmanage_host(host)
    curl = setup_curl("#{@foreman_url}/api/hosts/#{host}", true)
    curl.headers['Accept'] = 'application/json,version=2'
    curl.headers['Content-Type'] = 'application/json'
    host_settings = {}
    host_settings[:host] = {}
    host_settings[:managed] = false
    host_settings_json = host_settings.to_json
    curl.http_post(host_settings_json)
    result = JSON.parse(curl.body_str)
    raise result['message'] if result['message'] =~ /^ERF51/
    result
  end

  # Pushes one host, with facts, up to foreman.
  def upload_facts(host_json, host = '')
    curl = setup_curl("#{@foreman_url}/api/hosts/facts")
    curl.headers['Accept'] = 'application/json,version=2'
    curl.headers['Content-Type'] = 'application/json'
    curl.http_post(host_json)
    result = JSON.parse(curl.body_str)
    raise result['message'] if result['message'] =~ /^ERF51/
    result
  rescue => e
    warn "Could not push #{host}: #{e}"
    false
  end

  # Upload all facts for all hosts from puppetdb.
  def upload_all_facts(hosts = @puppetdb_hosts)
    hosts.each do |host|
      raw_facts = get_facts(host)
      host_json = squash_facts(host, raw_facts)
      upload_facts(host_json)
    end
  end

  # Just keeping it DRY
  def setup_curl(uri, auth = false, use_puppet_certs = false)
    curl = Curl::Easy.new("#{uri}")
    if auth
      curl.http_auth_types = :basic
      curl.username = @foreman_user
      curl.password = @foreman_pass
    end
    # puppetdb will want to verify client certs if using https
    if @use_puppet_certs
      curl.cacert = "#@puppetdir/ssl/certs/ca.pem"
      curl.cert = "#@puppetdir/ssl/certs/#{ENV['HOSTNAME']}.pem"
      curl.cert_key = "#@puppetdir/ssl/private_keys/#{ENV['HOSTNAME']}.pem"
    end
    curl.ssl_verify_host = false
    curl.ssl_verify_peer = false
    curl
  end
end

if __FILE__ == $0
  fpush = FactPush.new(puppetdb_url,
                       foreman_url,
                       foreman_user,
                       foreman_pass)
  if ARGV[0] != nil
    host = ARGV[0]
    raw_facts = fpush.get_facts(host)
    host_json = fpush.squash_facts(host, raw_facts)
    result = fpush.upload_facts(host_json, host)
    puts JSON.pretty_generate(result) if result
  else
    fpush.get_puppetdb_hosts
    fpush.get_foreman_hosts
    fpush.upload_all_facts
    fpush.hosts_delta
    fpush.host_delete_all
  end
end
