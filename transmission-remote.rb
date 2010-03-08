#!/usr/bin/ruby
require 'rubygems'
require 'nokogiri'
require 'net/http'
require 'json'

def list(host, port)
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

torrents = {}
peers = File.open('peers').readlines.map(&:chomp).map(&:split)
peers.each do |peer|
  host, port = peer[0], peer[1].to_i
  tr = list(host, port)
  tr['arguments']['torrents'].each do |t|
    h = t['hashString']
    torrents[h] = { :name => t['name'], :peers => [] } unless torrents.key?(h)
    torrents[h][:peers] << [host, port].join(':')
  end
end

torrents.each do |hash, t|
  puts "%d %s" % [t[:peers].size, t[:name]]
end
