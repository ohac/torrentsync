#!/usr/bin/ruby
require 'rubygems'
require 'nokogiri'
require 'net/http'
require 'json'
require 'timeout'
require 'fileutils'
require 'open-uri'

def transmission_list(host, port)
  Net::HTTP.start(host, port) do |http|
    res = http.get('/transmission/rpc')
    h = Nokogiri::HTML.parse(res.body)
    sessionid = h.css('code').text.split.last
    header = {
      'X-Transmission-Session-Id' => sessionid,
      'Content-Type' => 'application/json',
    }
    json = {
      :method => 'torrent-get',
      :arguments => { :fields => [ :hashString, :id, :name ] }
    }
    res = http.post('/transmission/rpc', json.to_json, header)
    JSON.parse(res.body)
  end
end

def utorrent_list(host, port, user, pass)
  Net::HTTP.start(host, port) do |http|
    req = Net::HTTP::Get.new('/gui/token.html')
    req.basic_auth user, pass
    res = http.request(req)
    h = Nokogiri::HTML.parse(res.body)
    token = h.css('#token').text
    req = Net::HTTP::Get.new('/gui/?list=1&token=%s' % token)
    req.basic_auth user, pass
    res = http.request(req)
    result = JSON.parse(res.body)
    transmissionlike = result['torrents'].map do |t|
      { 'hashString' => t[0].downcase, 'name' => t[2] }
    end
    { 'arguments' => { 'torrents' => transmissionlike } }
  end
end

HOME_DIR = ENV['HOME']
SETTING_DIR = "#{HOME_DIR}/.torrentsync"
PEERS_FILE = File.join(SETTING_DIR, 'peers')
TORRENTS_FILE = File.join(SETTING_DIR, 'torrents')
unless File.exist?(SETTING_DIR)
  FileUtils.mkdir SETTING_DIR
  open(PEERS_FILE, 'w') do |fd|
    fd.puts('transmission localhost 9091')
  end
  open(TORRENTS_FILE, 'w') do |fd|
    fd.puts("file:#{HOME_DIR}/.config/transmission/torrents")
  end
end

def find_torrent(name)
  uris = File.open(TORRENTS_FILE).readlines.map(&:chomp).map{|u| URI.parse(u)}
  rv = nil
  uris.each do |uri|
    ts = case uri.scheme
    when 'file'
      Dir.glob(File.join(uri.path, '*.torrent')).map{|t|File.basename(t)}
    when 'http'
      body = open(uri).read
      h = Nokogiri::HTML.parse(body)
      h.css('a').map{|a| a.text}.select{|t| /\.torrent$/ === t}
    else
      raise
    end
    rv = ts.find{|t| !t.index(name).nil?}
    next if rv.nil?
    rv = URI.parse(URI.encode("#{uri.to_s}/#{rv}"))
    break
  end
  rv
end

torrents = {}
peers = File.open(PEERS_FILE).readlines.map(&:chomp).map(&:split)
peers.each do |peer|
  type = peer[0]
  next if type[0, 1] == '#'
  host, port, user, pass = peer[1], peer[2].to_i, peer[3], peer[4]
  tr = begin
    timeout(2) do
      case type
      when 'transmission'
        transmission_list(host, port)
      when 'utorrent'
        utorrent_list(host, port, user, pass)
      end
    end
  rescue TimeoutError
    nil
  end
  next if tr.nil?
  tr['arguments']['torrents'].each do |t|
    h = t['hashString']
    torrents[h] = { :name => t['name'], :peers => [] } unless torrents.key?(h)
    torrents[h][:peers] << [host, port].join(':')
  end
end

torrents.each do |hash, t|
  name = t[:name]
  found = find_torrent(t[:name]).nil? ? '0' : '1'
  puts "%d %s %s" % [t[:peers].size, found, name]
end
