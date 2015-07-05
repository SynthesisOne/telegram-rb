# encoding: utf-8
require 'eventmachine'
require "em-synchrony"
require 'em-synchrony/fiber_iterator'
require 'ostruct'
require 'oj'
require 'shellwords'
require 'date'

require 'telegram/connection'
require 'telegram/connection_pool'
require 'telegram/callback'
require 'telegram/api'
require 'telegram/models'
require 'telegram/events'

module Telegram
  class Client < API
    attr_reader :connection

    attr_reader :profile
    attr_reader :contacts
    attr_reader :chats

    attr_accessor :on

    def initialize(&b)
      @config = OpenStruct.new(:daemon => 'bin/telegram', :key => 'tg-server.pub', :sock => 'tg.sock', :size => 5)
      yield @config
      @connected = 0
      @stdout = nil
      @connect_callback = nil
      @on = {
        :message => nil
      }

      @profile = nil
      @contacts = []
      @chats = []
      @starts_at = nil
      @events = EM::Queue.new
    end

    def execute
      command = "'#{@config.daemon}' -Ck '#{@config.key}' -I -WS '#{@config.sock}' --json"
      @stdout = IO.popen(command)
      p @stdout
      loop do
        if t = @stdout.readline then
          break if t.include?('I: config')
        end
      end
      proc {}
    end

    def poll
      data = ''
      loop do
        begin
          byte = @stdout.read_nonblock 1
        rescue IO::WaitReadable
          print 'wait readable.. '
          IO.select([@stdout])
          retry
        rescue EOFError
          p @pid
          retry
        end
        data << byte unless @starts_at.nil?
        if byte.include?("\n")
          begin
            brace = data.index('{')
            data = data[brace..-2]
            data = Oj.load(data)
            @events << data
          rescue
          end
          data = ''
        end
      end
    end

    def process_data
      process = Proc.new { |data|
          type = case data['event']
          when 'message'
            if data['from']['id'] != @profile.id
              EventType::RECEIVE_MESSAGE
            else
              EventType::SEND_MESSAGE
            end
          end

          action = data.has_key?('action') ? case data['action']
            when 'chat_add_user'
              ActionType::CHAT_ADD_USER
            else
              ActionType::UNKNOWN_ACTION
            end : ActionType::NO_ACTION

          event = Event.new(self, type, action, data)
          if type == EventType::RECEIVE_MESSAGE
            p 'send'
            event.tgmessage.reply(:text, ' 가 나 다 라 마 ')
          end
          @events.pop(&process)
        }
        @events.pop(&process)
    end

    def connect(&block)
      @connect_callback = block
      process_data
      EM.defer(execute, create_pool)
    end

    def create_pool
      @connection = ConnectionPool.new(@config.size) do
        client = EM.connect_unix_domain(@config.sock, Connection)
        client.on_connect = self.method(:on_connect)
        client.on_disconnect = self.method(:on_disconnect)
        client
      end
      proc {}
    end

    def on_connect
      @connected += 1
      if connected?
        EM.defer(&method(:poll))
        update!(&@connect_callback)
      end
    end

    def on_disconnect
      @connected -= 1
    end

    def connected?
      @connected == @config.size
    end
  end
end
