#!/usr/bin/ruby
require 'rubygems'
require 'nokogiri'
require 'net/http'
require 'json'
require 'timeout'
require 'fileutils'
require 'open-uri'
require 'base64'

class Transmission
  def initialize(host, port, user = nil, pass = nil)
    @host = host
    @port = port
    @user = user
    @pass = pass
  end

  def list
    Net::HTTP.start(@host, @port) do |http|
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

  # TODO DRY
  def add(torrent)
    Net::HTTP.start(@host, @port) do |http|
      res = http.get('/transmission/rpc')
      h = Nokogiri::HTML.parse(res.body)
      sessionid = h.css('code').text.split.last
      header = {
        'X-Transmission-Session-Id' => sessionid,
        'Content-Type' => 'application/json',
      }
      json = {
        :method => 'torrent-add',
        :arguments => { :metainfo => Base64::encode64(torrent) }
      }
      http.post('/transmission/rpc', json.to_json, header)
    end
  end

end

class UTorrent
  def initialize(host, port, user = nil, pass = nil)
    @host = host
    @port = port
    @user = user
    @pass = pass
  end

  def list
    Net::HTTP.start(@host, @port) do |http|
      req = Net::HTTP::Get.new('/gui/token.html')
      req.basic_auth @user, @pass
      res = http.request(req)
      h = Nokogiri::HTML.parse(res.body)
      token = h.css('#token').text
      req = Net::HTTP::Get.new('/gui/?list=1&token=%s' % token)
      req.basic_auth @user, @pass
      res = http.request(req)
      result = JSON.parse(res.body)
      transmissionlike = result['torrents'].map do |t|
        { 'hashString' => t[0].downcase, 'name' => t[2] }
      end
      { 'arguments' => { 'torrents' => transmissionlike } }
    end
  end

  # TODO DRY
  def add(torrent)
    Net::HTTP.start(@host, @port) do |http|
      req = Net::HTTP::Get.new('/gui/token.html')
      req.basic_auth @user, @pass
      res = http.request(req)
      h = Nokogiri::HTML.parse(res.body)
      token = h.css('#token').text
      req = Net::HTTP::Post.new('/gui/?action=add-file&token=%s' % token)
      req.basic_auth @user, @pass
      req.set_content_type('multipart/form-data; boundary=myboundary')
      req.body = <<EOF
--myboundary\r
Content-Disposition: form-data; name="torrent_file"\r
Content-Type: application/octet-stream\r
Content-Transfer-Encoding: binary\r
\r
#{torrent}\r
--myboundary--\r
EOF
      http.request(req)
    end
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
    rp = ts.find{|t| !t.index(name).nil?}
    next if rp.nil?
    uri2 = URI.parse(URI.encode("#{uri.to_s}/#{rp}"))
    rv = case uri2.scheme
        when 'file'
          open(uri2.path){|f|f.read}
        when 'http'
          open(uri2){|f|f.read}
        end
    # TODO need to check info_hash too
    break
  end
  rv
end

def type2class(type)
  case type
  when 'transmission'
    Transmission
  when 'utorrent'
    UTorrent
  end
end

torrents = {}
peers = File.open(PEERS_FILE).readlines.map(&:chomp).map(&:split)
peers.each do |peer|
  type = peer[0]
  next if type[0, 1] == '#'
  host, port, user, pass = peer[1], peer[2].to_i, peer[3], peer[4]
  tr = begin
    timeout(2) do
      type2class(type).new(host, port, user, pass).list
    end
  rescue TimeoutError, Errno::ECONNREFUSED
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
  hps = t[:peers]
  next if hps.size >= 2
  body = find_torrent(name)
  next if body.nil?
  hps = hps.map{|hp| host, port = hp.split(':'); [host, port.to_i]}
  dests = peers.select do |peer|
    hps.any?{|hp| peer[1] != hp[0] && peer[2] != hp[1]}
  end
  dest = dests.shuffle.first
  puts "mirroring: %s to %s" % [name, dest.join(',')]
  type = dest[0]
  host, port, user, pass = dest[1], dest[2].to_i, dest[3], dest[4]
  dest = type2class(type).new(host, port, user, pass)
  dest.add(body)
end
