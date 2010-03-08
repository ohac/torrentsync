#!/usr/bin/ruby
require 'rubygems'
require 'nokogiri'
require 'net/http'
require 'json'

Net::HTTP.start("localhost", 9091) do |http|
  res = http.get('/transmission/rpc')
  h = Nokogiri::HTML.parse(res.body)
  sessionid = h.css('code').text.split.last
  header = {
    'X-Transmission-Session-Id' => sessionid,
    'Content-Type' => 'application/json',
  }
  json = {
    :method => 'torrent-get',
    :arguments => { :fields => [ :hashString, :id ] }
  }
  res = http.post('/transmission/rpc', json.to_json, header)
  p JSON.parse(res.body)
end
