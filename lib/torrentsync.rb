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
require 'socket'
require 'openssl'
require 'zlib'
require 'rencode'

class Transmission
  def initialize(host, port, user = nil, pass = nil)
    @host = host
    @port = port
    @user = user
    @pass = pass
  end

  def exec(command, arguments)
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
        :method => command,
        :arguments => arguments
      }
      res = http.post('/transmission/rpc', json.to_json, header)
      JSON.parse(res.body)
    end
  end

  def list
    exec('torrent-get', {
      :fields => [ :hashString, :id, :name, :totalSize, :haveValid ]
    })
  end

  def add(torrent)
    exec('torrent-add', :metainfo => Base64::encode64(torrent))
  end

  def remove(torrentid, removedata = false)
    exec('torrent-remove', :ids => [torrentid],
        'delete-local-data' => removedata)
  end
end

class UTorrent
  def initialize(host, port, user = nil, pass = nil)
    @host = host
    @port = port
    @user = user
    @pass = pass
  end

  def gettoken(http)
    req = Net::HTTP::Get.new('/gui/token.html')
    req.basic_auth @user, @pass
    res = http.request(req)
    h = Nokogiri::HTML.parse(res.body)
    h.css('#token').text
  end

  def list
    Net::HTTP.start(@host, @port) do |http|
      token = gettoken(http)
      req = Net::HTTP::Get.new('/gui/?list=1&token=%s' % token)
      req.basic_auth @user, @pass
      res = http.request(req)
      result = JSON.parse(res.body)
      transmissionlike = result['torrents'].map do |t|
        { 'hashString' => t[0].downcase, 'name' => t[2],
          'totalSize' => 1000, 'haveValid' => t[4] } # FIXME
      end
      { 'arguments' => { 'torrents' => transmissionlike } }
    end
  end

  def add(torrent)
    Net::HTTP.start(@host, @port) do |http|
      token = gettoken(http)
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

  def remove(torrentid, removedata = false)
    Net::HTTP.start(@host, @port) do |http|
      token = gettoken(http)
      req = Net::HTTP::Get.new('/gui/?action=%s&hash=%s&token=%s' %
          [removedata ? 'removedata' : 'remove', torrentid, token])
      req.basic_auth @user, @pass
      res = http.request(req)
      JSON.parse(res.body)
    end
  end
end

class Deluge
  def initialize(host, port, user = nil, pass = nil)
    @host = host
    @port = port
    @user = user
    @pass = pass
  end

  def exec(command)
    soc = TCPSocket.new(@host, @port)
    context = OpenSSL::SSL::SSLContext.new('SSLv3')
    ssl = OpenSSL::SSL::SSLSocket.new(soc, context)
    ssl.connect

    cmd = REncode.dump([[1, 'daemon.login', [@user, @pass], {}]] + [command])
    ssl.write(Zlib::Deflate.deflate(cmd))
    gz = Zlib::Inflate.new
    while !gz.finished?
      gz << ('%c' % ssl.readchar.ord)
    end
    result = REncode.load(gz.finish)
    raise result if result != [1, 1, 10]

    gz = Zlib::Inflate.new
    while !gz.finished?
      gz << ('%c' % ssl.readchar.ord)
    end
    result = REncode.load(gz.finish)
    raise result if result[0] != 1

    ssl.close
    soc.close
    result
  end

  def list
    result = exec([2, 'core.get_torrents_status', [{},
        ['name', 'progress', 'total_size']], {}])
    transmissionlike = result[2].map do |k, v|
      size = v['total_size']
      have = (size * v['progress'] / 100).to_i
      { 'hashString' => k, 'name' => v['name'],
        'totalSize' => size, 'haveValid' => have }
    end
    { 'arguments' => { 'torrents' => transmissionlike } }
  end

  def add(torrent)
    filename = BEncode.load(torrent)['info']['name'] + '.torrent'
    filedump = Base64.encode64(torrent).split.join
    exec([2, 'core.add_torrent_file', [filename, filedump, {}], {}])
  end

  def remove(torrentid, removedata = false)
    exec([2, 'core.remove_torrent', [torrentid, removedata], {}])
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
          'nick' => 'localpeer',
          'client' => 'transmission',
          'host' => 'localhost',
          'port' => 9091,
          'username' => '',
          'password' => '',
          'limit' => '10MB',
          'size' => '10GB',
        }
      ],
      'torrents' => [
        "file:#{HOME_DIR}/.config/transmission/torrents"
      ],
      'local' => {
        'download' => "#{HOME_DIR}/Downloads",
        'torrents' => "#{SETTING_DIR}/torrents.d",
        'peer' => 'localpeer',
        'tracker' => 'http://localhost:4567/announce'
      },
      'webseeds' => [ 'http://example.com/' ],
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
    ts.find do |rp|
      next if rp.index(name).nil?
      uri2 = URI.parse(("#{uri.to_s}/#{URI.encode(rp)}").gsub('[', '%5B').gsub(
          ']', '%5D'))
      rv2 = case uri2.scheme
          when 'file'
            open(URI.decode(uri2.path)){|f|f.read}
          when 'http'
            open(uri2){|f|f.read}
          end
      info = BEncode.load(rv2)['info']
      info_hash = Digest::SHA1.digest(BEncode.dump(info))
      hashstr = info_hash.unpack('C*').map{|v|"%02x" % v}.join
      next if hash != hashstr
      rv = rv2
    end
    break if rv
  end
  rv
end

def type2class(type)
  case type
  when 'transmission'
    Transmission
  when 'utorrent'
    UTorrent
  when 'deluge'
    Deluge
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

def find_peer_setting(host, port)
  SETTING['peers'].find do |i|
    i['host'] == host and i['port'].to_i == port
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
    sleep 0.5 # FIXME need to see the number of CPU cores
  end
  es.map do
    result, th = q.pop
    th.join
    result
  end
end

$failed = {}
def get_torrents(peers, usecache = true)
  trs = parallelmap(peers) do |peer|
    type = peer[0]
    next if type[0, 1] == '#'
    host, port, user, pass = peer[1], peer[2].to_i, peer[3], peer[4]
    cache = "#{host}_#{port}"
    tr = load_from_cache(cache)
    modified = tr && tr['modified']
    now = Time.now.to_i
    st = :live
    if !usecache or modified.nil? or now >= modified + 60
      begin
        raise TimeoutError if !$failed[peer].nil? and now < $failed[peer] + 60
        curtr = timeout(10) do
          type2class(type).new(host, port, user, pass).list
        end
        curtr['modified'] = now
        save_to_cache(cache, curtr)
        tr = curtr
      rescue TimeoutError, Errno::ECONNREFUSED, Errno::EHOSTUNREACH
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
      unless torrents.key?(h)
        torrents[h] = { :name => t['name'], :peers => [],
            :size => t['totalSize'] }
      end
      ratio = t['haveValid'] ? t['haveValid'] * 1.0 / t['totalSize'] : 0.0
      torrents[h][:peers] << [[host, port].join(':'), ratio]
    end
  end
  [torrents, status]
end

def parse_size(str)
  size = str.to_i
  if str.index('T')
    size * (1024 ** 4)
  elsif str.index('G')
    size * (1024 ** 3)
  elsif str.index('M')
    size * (1024 ** 2)
  elsif str.index('K')
    size * 1024
  else
    size
  end
end

def sync_torrent(peers, t, hash, rep, dryrun = false)
  name = t[:name]
  hps = t[:peers]
  tsize = t[:size]
  return if hps.size >= rep
  body = find_torrent_by_name(name, hash)
  return if body.nil?
  hps = hps.map{|hp| host, port = hp[0].split(':'); [host, port.to_i]}
  dests = peers.select do |peer|
    hps.all?{|hp| peer[1] != hp[0] || peer[2] != hp[1]}
  end
  dests = dests.select do |peer|
    setting = find_peer_setting(peer[1], peer[2])
    next if setting.nil?
    limit = setting['limit']
    tsize < parse_size(limit) rescue nil
  end
  count = rep - hps.size
  dests2 = dests.map do |peer|
    setting = find_peer_setting(peer[1], peer[2])
    next if setting.nil?
    size = setting['size']
    [(parse_size(size) rescue 1), peer]
  end
  dests = count.times.map do
    total = dests2.inject(0){|t,i|t+i[0]}
    dice = rand * total.to_f
    winner = dests2.find do |item|
      dice -= item[0]
      dice < 0
    end
    dests2 -= [winner]
    winner.nil? ? nil : winner[1] # FIXME why nil?
  end
  dests.compact!
  return if dests.empty?
  rv = dests.map do |dest|
    type = dest[0]
    host, port, user, pass = dest[1], dest[2].to_i, dest[3], dest[4]
    dest = type2class(type).new(host, port, user, pass)
    begin
      dest.add(body) unless dryrun
      [host, port]
    rescue
    end
  end
  rv.compact
end

def sync_torrents(peers, torrents, rep, dryrun = false)
  torrents.each do |hash, t|
    dests = sync_torrent(peers, t, hash, rep, dryrun)
    next if dests.nil?
    name = t[:name]
    dests.each do |dest|
      host, port = dest
      puts "mirroring: %s to %s:%d" % [name, host, port]
    end
  end
end
