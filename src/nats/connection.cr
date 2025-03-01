# Copyright 2019 The NATS Authors
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require "socket"
require "uri"
require "json"
require "openssl"

require "./nuid"
require "./msg"
require "./subscription"

module NATS
  VERSION = "0.0.1"
  LANG    = "crystal"

  class Connection
    # :nodoc:
    DEFAULT_PORT = 4222
    # :nodoc:
    DEFAULT_AUTH_PORT = 4443
    # :nodoc:
    DEFAULT_PRE = "nats://127.0.0.1:"
    # :nodoc:
    DEFAULT_URI = URI.parse("#{DEFAULT_PRE}#{DEFAULT_PORT}")
    # :nodoc:
    BUFFER_SIZE = 32768
    # :nodoc:
    MAX_PAYLOAD = 1_000_000

    getter? closed
    getter max_payload

    # Creates a new connection to a NATS Server.
    #
    # ```
    # nc = NATS::Connection.new("demo.nats.io")
    # nc = NATS::Connection.new("tls://demo.nats.io")
    # nc = NATS::Connection.new("nats://#{user}:#{pass}@127.0.0.1:4222")
    # nc = NATS::Connection.new(4222, name: "Sample App", user: "derek", pass: "s3cr3t")
    # nc = NATS::Connection.new(4222)
    # nc = NATS::Connection.new
    # ```
    def initialize(
      host, port,
      @user : String? = nil,
      @pass : String? = nil,
      @name : String? = nil,
      @echo = true,
      @pedantic = false
    )
      # For new style INBOX behavior.
      @nuid = NUID.new
      @resp_sub_prefix = "_INBOX.#{@nuid.next}"
      @rand = Random.new

      # This will be updated when we receive an INFO from the server.
      @max_payload = MAX_PAYLOAD

      # For flush
      @pongs = Deque(Channel(Nil)).new

      # FIXME(dlc) - timeouts on connect.
      # dns_timeout = nil, connect_timeout = nil
      @socket = TCPSocket.new(host, port)
      if (s = @socket).is_a?(TCPSocket)
        s.tcp_nodelay = true
        s.sync = true
        s.read_buffering = true
        s.buffer_size = BUFFER_SIZE
      end

      # For efficient batched writes
      @buf = IO::Memory.new(BUFFER_SIZE)
      @out = Mutex.new

      @closed = false
      @gsid = 0
      @subs = {} of Int32 => (Subscription | InternalSubscription)
      @resp_map = {} of String => Channel(Msg?)
      @resp_sub_created = false

      # read in the INFO block here inline before we start up
      # the inbound fiber.
      # TODO(dlc) put read timeout here.
      @server_info = uninitialized Hash(String, JSON::Any)
      process_first_info

      # send connect
      send_connect

      # FIXME(dlc) - make sure we do not have auth error etc.
      # send ping and expect pong.
      connect_ok?

      # spawn our inbound processing fiber
      spawn inbound

      # spawn for our outbound
      @flush = Channel(Bool?).new(8)
      spawn outbound
    end

    # :nodoc:
    def self.new(**args)
      new(DEFAULT_URI, **args)
    end

    # :nodoc:
    def self.new(port : Int, **args)
      new(URI.parse("#{DEFAULT_PRE}#{port}"), **args)
    end

    # :nodoc:
    def self.new(url : String, **args)
      # We want to allow simple strings, e.g. demo.nats.io
      # so make sure to add on scheme and port if needed.
      url = "nats://#{url}" unless url.includes? "://"
      unless url.index(/:\d/) != nil
        url = "#{url}:#{DEFAULT_PORT}" if url.starts_with? "nats"
        url = "#{url}:#{DEFAULT_AUTH_PORT}" if url.starts_with? "tls"
      end
      new(URI.parse(url), **args)
    end

    # :nodoc:
    def self.new(uri : URI, **args)
      host = uri.host
      port = uri.port
      raise "Invalid URI" if host.nil? || port.nil?
      new(host, port, uri.user, uri.password, **args)
    end

    private def out_sync
      @out.synchronize do
        yield
      end
      @flush.send(true) if @flush.empty?
    end

    private def check_size(data)
      if data.size > @max_payload
        raise "Payload too big"
      end
    end

    # Publishes a messages to a given subject.
    #
    # ```
    # nc = NATS::Connection.new("demo.nats.io")
    # nc.publish("foo", "Hello!")
    # ```
    def publish(subject : String, msg)
      # raise ArgumentError.new("Connection closed") if closed?
      raise "Bad Subject" if subject.empty?
      raise "Connection Closed" if closed?

      data = msg.to_slice
      check_size(data)

      @out.synchronize do
        @buf.write(PUB_SLICE)
        @buf.write("#{subject} #{data.size}".to_slice)
        @buf.write(CR_LF_SLICE)
        @buf.write(data)
        @buf.write(CR_LF_SLICE)
      end
      @flush.send(true) if @flush.empty?
    end

    # Publishes an empty message to a given subject.
    #
    # ```
    # nc = NATS::Connection.new("demo.nats.io")
    # nc.publish("foo")
    # ```
    def publish(subject : String)
      raise "Bad Subject" if subject.empty?
      raise "Connection Closed" if closed?

      @out.synchronize { @buf.write("PUB #{subject} 0\r\n\r\n".to_slice) }
      @flush.send(true) if @flush.empty?
    end

    # Publishes a messages to a given subject with a reply subject.
    #
    # ```
    # nc = NATS::Connection.new("demo.nats.io")
    # nc.publish_with_reply("foo", "reply", "Hello!")
    # ```
    def publish_with_reply(subject, reply : String, msg)
      raise "Bad Subject" if subject.empty?
      raise "Connection Closed" if closed?

      data = msg.to_slice
      check_size(data)

      @out.synchronize do
        @buf.write(PUB_SLICE)
        @buf.write("#{subject} #{reply} #{data.size}".to_slice)
        @buf.write(CR_LF_SLICE)
        @buf.write(data)
        @buf.write(CR_LF_SLICE)
      end
      @flush.send(true) if @flush.empty?
    end

    # ditto
    def publish_with_reply(subject, reply : String, msg)
      raise "Bad Subject" if subject.empty?
      raise "Connection Closed" if closed?

      @out.synchronize { @buf.write("PUB #{subject} #{reply} 0\r\n\r\n".to_slice) }
      @flush.send(true) if @flush.empty?
    end

    # Flush will flush the connection to the server. Can specify a *timeout*.
    def flush(timeout = 2.second)
      ch = Channel(Nil).new
      @pongs.push(ch)
      @out.synchronize { @buf.write(PING_SLICE) }
      flush_outbound
      spawn { sleep timeout; ch.close }
      ch.receive rescue {raise "Flush Timeout"}
    end

    def new_inbox
      "#{@resp_sub_prefix}.#{inbox_token}"
    end

    # :nodoc:
    TOKEN_LENGTH = 8 # Matches Go implementation

    private def inbox_token
      rn = @rand.rand(Int64::MAX)
      String::Builder.build(TOKEN_LENGTH) do |io|
        (0...TOKEN_LENGTH).each do
          io << "#{NUID::DIGITS[rn % NUID::BASE]}"
          rn /= NUID::BASE
        end
      end
    end

    private def create_resp_subscription
      return if @resp_sub_created
      @resp_sub_created = true
      internal_subscribe("#{@resp_sub_prefix}.*")
    end

    protected def handle_resp(msg)
      token = msg.subject[@resp_sub_prefix.size + 1..-1]
      ch = @resp_map[token]
      ch.send(msg)
      @resp_map.delete(token)
    end

    # Request will send a request to the given subject and wait up to *timeout* for a response.
    #
    # ```
    # nc = NATS::Connection.new("demo.nats.io")
    # answer = nc.request("req", "Help!")
    # puts "Received a response '#{answer}'!"
    # ```
    def request(subject : String, msg?, timeout = 2.second)
      create_resp_subscription unless @resp_sub_created
      token = inbox_token
      reply = "#{@resp_sub_prefix}.#{token}"
      ch = Channel(Msg?).new
      @resp_map[token] = ch
      publish_with_reply(subject, reply, msg?)
      spawn { sleep timeout; ch.close }
      begin
        msg = ch.receive
      rescue
        @resp_map.delete(token)
        raise "Request Timeout"
      end
    end

    private def internal_subscribe(subject : String)
      sid = @gsid += 1
      @out.synchronize { @buf << "SUB " << subject << " #{sid}\r\n" }
      @flush.send(true) if @flush.empty?
      InternalSubscription.new(sid, self).tap do |sub|
        @subs[sid] = sub
      end
    end

    # Subscribe to a given subject. Will yield to the callback provided with the message received.
    #
    # ```
    # nc = NATS::Connection.new("demo.nats.io")
    # nc.subscribe("foo") { |msg| puts "Received '#{msg}'" }
    # ```
    def subscribe(subject : String, &callback : Msg ->)
      sid = @gsid += 1
      @out.synchronize { @buf << "SUB " << subject << " #{sid}\r\n" }
      @flush.send(true) if @flush.empty?
      Subscription.new(sid, self, callback).tap do |sub|
        @subs[sid] = sub
      end
    end

    # Subscribe to a given subject with the queue group. Will yield to the callback provided with the message received.
    #
    # ```
    # nc = NATS::Connection.new("demo.nats.io")
    # nc.subscribe("foo", "group1") { |msg| puts "Received '#{msg}'" }
    # ```
    def subscribe(subject, queue : String, &callback : Msg ->)
      sid = @gsid += 1
      @out.synchronize { @buf << "SUB " << subject << " " << queue << " #{sid}\r\n" }
      @flush.send(true) if @flush.empty?
      Subscription.new(sid, self, callback).tap do |sub|
        @subs[sid] = sub
      end
    end

    def subscribe(subject : String, queue : String | Nil, &callback : Msg ->)
      return subscribe(subject, queue, &callback) if queue.is_a?(String)
      subscribe(subject, &callback)
    end

    protected def unsubscribe(sid)
      return if closed?
      @out.synchronize { @buf << "UNSUB #{sid}\r\n" }
      @flush.send(true) if @flush.empty?
    end

    # Close a connection to the NATS server.
    #
    # ```
    # nc = NATS::Connection.new("demo.nats.io")
    # nc.close
    # ```
    def close
      return if @closed
      @closed = true
      @out.synchronize do
        flush_outbound
        @socket.flush
      end
      @socket.close
      @subs.each { |sid, sub| sub.unsubscribe }
      # TODO(dlc) - pop any calls in flush.
      @close_cb.try do |cb|
        spawn cb.call
      end
    end

    # Setup a callback for when the connection closes.
    #
    # ```
    # nc = NATS::Connection.new("demo.nats.io")
    # nc.on_close { puts "Connection closed!" }
    # nc.close
    # ```
    def on_close(&callback)
      @close_cb = callback
    end

    # Setup a callback for an async errors that are received.
    #
    # ```
    # nc = NATS::Connection.new("demo.nats.io")
    # nc.on_error { |e| puts "Received an error #{e}" }
    # ```
    def on_error(&callback : String ->)
      @err_cb = callback
    end

    # :nodoc:
    def finalize
      close unless closed?
    end

    # :nodoc:
    INFO = /\AINFO\s+([^\r\n]+)/i
    # :nodoc:
    MSG = /\AMSG\s+([^\s]+)\s+([^\s]+)\s+(([^\s]+)[^\S\r\n]+)?(\d+)/i
    # :nodoc:
    PING = /\APING\s*/i
    # :nodoc:
    PONG = /\APONG\s*/i
    # :nodoc:
    ERR = /\A-ERR\s+('.+')?/i
    # :nodoc:
    OK = /\A\+OK\s*/i

    # :nodoc:
    CR_LF = "\r\n"
    # :nodoc:
    CR_LF_SLICE = CR_LF.to_slice
    # :nodoc:
    PUB_SLICE = "PUB ".to_slice
    # :nodoc:
    PING_SLICE = "PING\r\n".to_slice
    # :nodoc:
    PONG_SLICE = "PONG\r\n".to_slice

    # TODO(dlc) - Performance is off from what I expected. Blind read *should* be handled by IO::Buffered.
    # Should try manual blind read and hand rolled parser similar to Golang. Also make sure Channels is not slowdown.
    private def inbound
      until closed?
        case data = @socket.gets(CR_LF)
        when MSG
          bytesize = $5.to_i
          sid = $2.to_i
          payload = Bytes.new(bytesize)
          @socket.read_fully?(payload) || raise "Unexpected EOF"
          @socket.gets(CR_LF)
          sub = @subs[sid]
          sub.send(Msg.new($1, payload, $4?, self)) unless sub.nil?
        when PING
          @out.synchronize { @buf.write(PONG_SLICE) }
          flush_outbound
        when PONG
          ch = @pongs.pop?
          ch.send(nil) unless ch.nil?
        when OK
        when ERR
          # TODO(dlc) - Not default to puts?
          puts "NATS: Received an ERR #{$1}" if @err_cb.nil?
          @err_cb.try do |cb|
            cb.call($1)
          end
        else
          raise "Protocol Error" unless data.to_s.empty?
          close
        end
      end
    rescue ex
      close
    end

    private def flush_outbound
      @out.synchronize do
        @socket.write(@buf.to_slice)
        @socket.flush
        @buf.clear
      end
    end

    private def outbound
      until closed?
        fs = @flush.receive
        break if fs.nil?
        flush_outbound
      end
    end

    private def connect_ok?
      auth_required = @server_info["auth_required"].as_bool rescue false
      tls_required = @server_info["tls_required"].as_bool rescue false
      return unless auth_required || tls_required
      # Don't need synchronize yet.

      @socket.write(PING_SLICE)
      @socket.flush
      case data = @socket.gets(CR_LF)
      when PONG
        return
      when ERR
        raise $1
      else
        raise "Connection Terminated"
      end
    end

    private def process_first_info
      # TODO(dlc) - timeouts
      line = @socket.read_line

      # TODO(dlc) - Could use JSON.mapping here with Info class.
      if match = line.match(INFO)
        info_json = match.captures.first
        @server_info = JSON.parse(info_json.to_s).as_h
        unless @server_info[:max_payload]?.nil?
          @max_payload = @server_info[:max_payload].as_i
        end
      else
        raise "INFO not valid"
      end

      # FIXME(dlc) - client side certs, etc.
      tls_required = @server_info["tls_required"].as_bool rescue false
      @socket = OpenSSL::SSL::Socket::Client.new(@socket) if tls_required
    end

    private def send_connect
      cs = {
        :verbose  => false,
        :pedantic => @pedantic,
        :lang     => LANG,
        :version  => VERSION,
        :protocol => 1,
      }
      cs[:name] = @name.to_s if @name

      cs[:user] = @user.to_s if @user
      cs[:pass] = @pass.to_s if @pass

      @socket << "CONNECT #{cs.to_json}\r\n"
    end
  end
end
