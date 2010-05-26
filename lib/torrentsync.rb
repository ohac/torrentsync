require 'rubygems'
require 'nokogiri'
require 'net/http'
require 'json'
require 'timeout'
require 'fileutils'
require 'open-uri'
require 'base64'
require 'bencode'
require 'digest/sha1'
require 'thread'

class Transmission
  def initialize(host, port, user = nil, pass = nil)
    @host = host
    @port = port
    @user = user
    @pass = pass
  end

  def list
    sessionid = Net::HTTP.start(@host, @port) do |http|
      res = http.get('/transmission/rpc')
      h = Nokogiri::HTML.parse(res.body)
      h.css('code').text.split.last
    end
    header = {
      'Content-Type' => 'application/json',
    }
    header['X-Transmission-Session-Id'] = sessionid unless sessionid.nil?
    sessionid = Net::HTTP.start(@host, @port) do |http|
      json = {
        :method => 'torrent-get',
        :arguments => {
          :fields => [ :hashString, :id, :name, :totalSize, :haveValid ]
        }
      }
      res = http.post('/transmission/rpc', json.to_json, header)
      JSON.parse(res.body)
    end
  end

  # TODO DRY
  def add(torrent)
    sessionid = Net::HTTP.start(@host, @port) do |http|
      res = http.get('/transmission/rpc')
      h = Nokogiri::HTML.parse(res.body)
      h.css('code').text.split.last
    end
    header = {
      'Content-Type' => 'application/json',
    }
    header['X-Transmission-Session-Id'] = sessionid unless sessionid.nil?
    Net::HTTP.start(@host, @port) do |http|
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
        { 'hashString' => t[0].downcase, 'name' => t[2],
          'totalSize' => 1000, 'haveValid' => t[4] }
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
SETTING_DIR = File.join(HOME_DIR, '.torrentsync')
SETTING_FILE = File.join(SETTING_DIR, 'settings.yaml')
CACHE_DIR = File.join(SETTING_DIR, 'cache')
unless File.exist?(SETTING_DIR)
  FileUtils.mkdir SETTING_DIR
  FileUtils.mkdir CACHE_DIR
end
unless File.exist?(SETTING_FILE)
  open(SETTING_FILE, 'w') do |fd|
    setting = {
      'peers' => [
        {
          'nick' => 'local',
          'client' => 'transmission',
          'host' => 'localhost',
          'port' => 9091,
          'username' => '',
          'password' => ''
        }
      ],
      'torrents' => [
        "file:#{HOME_DIR}/.config/transmission/torrents"
      ]
    }
    fd.puts(YAML.dump(setting))
  end
end

SETTING = YAML.load(File.read(SETTING_FILE))

def find_torrent_by_name(name, hash)
  uris = SETTING['torrents'].map{|u| URI.parse(u)}
  rv = nil
  uris.each do |uri|
    ts = case uri.scheme
    when 'file'
      fn = File.join(URI.decode(uri.path), '*.torrent')
      Dir.glob(fn).map{|t|File.basename(t)}
    when 'http'
      body = open(uri).read
      h = Nokogiri::HTML.parse(body)
      h.css('a').map{|a| a.text}.select{|t| /\.torrent$/ === t}
    else
      raise
    end
    rp = ts.find{|t| !t.index(name).nil?}
    next if rp.nil?
    uri2 = URI.parse(("#{uri.to_s}/#{URI.encode(rp)}").gsub('[', '%5B').gsub(
        ']', '%5D'))
    rv = case uri2.scheme
        when 'file'
          open(URI.decode(uri2.path)){|f|f.read}
        when 'http'
          open(uri2){|f|f.read}
        end
    info = BEncode.load(rv)['info']
    info_hash = Digest::SHA1.digest(BEncode.dump(info))
    hashstr = info_hash.unpack('C*').map{|v|"%02x" % v}.join
    next if hash != hashstr
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

def get_peers
  SETTING['peers'].map do |i|
    vs = ['client', 'host', 'port', 'username', 'password'].map do |j|
      v = i[j]
      v.size == '' ? nil : v
    end
    vs.compact
  end
end

def save_to_cache(id, status)
  File.open(File.join(CACHE_DIR, id), 'w') do |f|
    f.write(status.to_json)
  end
end

def load_from_cache(id)
  fn = File.join(CACHE_DIR, id)
  JSON.load(File.read(fn)) if File.exist?(fn)
end

def parallelmap(es)
  q = Queue.new
  ts = es.map do |x|
    Thread.new(x) do |y|
      result = yield(y) rescue nil
      q << [result, Thread.current]
    end
  end
  es.map do
    result, th = q.pop
    th.join
    result
  end
end

$failed = {}
def get_torrents(peers)
  trs = parallelmap(peers) do |peer|
    type = peer[0]
    next if type[0, 1] == '#'
    host, port, user, pass = peer[1], peer[2].to_i, peer[3], peer[4]
    cache = "#{host}_#{port}"
    tr = load_from_cache(cache)
    modified = tr && tr['modified']
    now = Time.now.to_i
    st = :live
    if modified.nil? or now >= modified + 60
      begin
        raise TimeoutError if !$failed[peer].nil? and now < $failed[peer] + 60
        curtr = timeout(2) do
          type2class(type).new(host, port, user, pass).list
        end
        curtr['modified'] = now
        save_to_cache(cache, curtr)
        tr = curtr
      rescue TimeoutError, Errno::ECONNREFUSED
        st = (!modified.nil? and now < modified + 7 * 24 * 60 * 60) ?
            :cached : :dead
        $failed[peer] = now
      end
    end
    [peer, st, st == :dead ? nil : tr]
  end
  torrents = {}
  status = {}
  trs.compact.each do |peer, st, tr|
    host, port, user, pass = peer[1], peer[2].to_i, peer[3], peer[4]
    status[peer] = st
    next if tr.nil?
    tr['arguments']['torrents'].each do |t|
      h = t['hashString']
      torrents[h] = { :name => t['name'], :peers => [] } unless torrents.key?(h)
      ratio = t['haveValid'] ? t['haveValid'] * 1.0 / t['totalSize'] : 0.0
      torrents[h][:peers] << [[host, port].join(':'), ratio]
    end
  end
  [torrents, status]
end

def sync_torrent(peers, t, hash, rep)
  name = t[:name]
  hps = t[:peers]
  return if hps.size >= rep
  body = find_torrent_by_name(name, hash)
  return if body.nil?
  hps = hps.map{|hp| host, port = hp[0].split(':'); [host, port.to_i]}
  dests = peers.select do |peer|
    hps.all?{|hp| peer[1] != hp[0] && peer[2] != hp[1]}
  end
  # TODO remove dead peers
  count = rep - hps.size
  dests = dests.shuffle.take(count)
  return if dests.empty?
  rv = dests.map do |dest|
    type = dest[0]
    host, port, user, pass = dest[1], dest[2].to_i, dest[3], dest[4]
    dest = type2class(type).new(host, port, user, pass)
    begin
      dest.add(body)
      [host, port]
    rescue
    end
  end
  rv.compact
end

def sync_torrents(peers, torrents, rep)
  torrents.each do |hash, t|
    dests = sync_torrent(peers, t, hash, rep)
    next if dests.nil?
    name = t[:name]
    dests.each do |dest|
      host, port = dest
      puts "mirroring: %s to %s:%d" % [name, host, port]
    end
  end
end
