# encoding: utf-8
require "logstash/inputs/base"
require "logstash/namespace"

# Receive events using the lumberjack protocol.
#
# This is mainly to receive events shipped with lumberjack[http://github.com/jordansissel/lumberjack],
# now represented primarily via the
# https://github.com/elasticsearch/logstash-forwarder[Logstash-forwarder].
#
class LogStash::Inputs::Lumberjack < LogStash::Inputs::Base

  config_name "lumberjack"

  default :codec, "plain"

  # The IP address to listen on.
  config :host, :validate => :string, :default => "0.0.0.0"

  # The port to listen on.
  config :port, :validate => :number, :required => true

  # SSL certificate to use.
  config :ssl_certificate, :validate => :path, :required => true

  # SSL key to use.
  config :ssl_key, :validate => :path, :required => true

  # SSL key passphrase to use.
  config :ssl_key_passphrase, :validate => :password

  # This setting no longer has any effect and will be removed in a future release.
  config :max_clients, :validate => :number, :deprecated => "This setting no longer has any effect. See https://github.com/logstash-plugins/logstash-input-lumberjack/pull/12 for the history of this change"

  # TODO(sissel): Add CA to authenticate clients with.

  BUFFERED_QUEUE_SIZE = 1
  RECONNECT_BACKOFF_SLEEP = 0.5
  
  def register
    require "lumberjack/server"
    require "concurrent/executors"
    require "logstash/circuit_breaker"
    require "logstash/sized_queue_timeout"

    @logger.info("Starting lumberjack input listener", :address => "#{@host}:#{@port}")
    @lumberjack = Lumberjack::Server.new(:address => @host, :port => @port,
      :ssl_certificate => @ssl_certificate, :ssl_key => @ssl_key,
      :ssl_key_passphrase => @ssl_key_passphrase)

    # Create a reusable threadpool, we do not limit the number of connections
    # to the input, the circuit breaker with the timeout should take care 
    # of `blocked` threads and prevent logstash to go oom.
    @threadpool = Concurrent::CachedThreadPool.new(:idletime => 15)

    # in 1.5 the main SizeQueue doesnt have the concept of timeout
    # We are using a small plugin buffer to move events to the internal queue
    @buffered_queue = LogStash::SizedQueueTimeout.new(BUFFERED_QUEUE_SIZE)

    @circuit_breaker = LogStash::CircuitBreaker.new("Lumberjack input",
                            :exceptions => [LogStash::SizedQueueTimeout::TimeoutError])

  end # def register

  def run(output_queue)
    start_buffer_broker(output_queue)

    while true do
      begin
        # Wrapping the accept call into a CircuitBreaker
        if @circuit_breaker.closed?
          connection = @lumberjack.accept # Blocking call that creates a new connection

          invoke(connection, codec.clone) do |_codec, line, fields|
            _codec.decode(line) do |event|
              File.open("/tmp/debug-received.log", "a") do |file|
                file.write("Event id #{event["message"]}\n")
              end

              decorate(event)
              fields.each { |k,v| event[k] = v; v.force_encoding(Encoding::UTF_8) }

              @circuit_breaker.execute { @buffered_queue << event }
            end
          end
        else
          @logger.warn("Lumberjack input: the pipeline is blocked, temporary refusing new connection.")
          sleep(RECONNECT_BACKOFF_SLEEP)
        end
        # When too many errors happen inside the circuit breaker it will throw 
        # this exception and start refusing connection, we need to catch it but 
        # it's safe to ignore.
      rescue LogStash::CircuitBreaker::OpenBreaker,
        LogStash::CircuitBreaker::HalfOpenBreaker => e
        logger.error("Lumberjack input: Connection closed, backing off")
        sleep(RECONNECT_BACKOFF_SLEEP)
      end
    end
  rescue LogStash::ShutdownSignal
    @logger.info("Lumberjack input: received ShutdownSignal")
  rescue => e
    @logger.error("Lumberjack input: unhandled exception", :exception => e, :backtrace => e.backtrace)
  ensure
    shutdown(output_queue)
  end # def run

  private
  def accept(&block)
    connection = @lumberjack.accept # Blocking call that creates a new connection
    block.call(connection, @codec.clone)
  end

  private
  def invoke(connection, codec, &block)
    @threadpool.post do
      connection.run do |fields|
        block.call(codec, fields.delete("line"), fields)
      end
    end
  end

  def start_buffer_broker(output_queue)
    @threadpool.post do
      while true
        output_queue << @buffered_queue.pop_no_timeout
      end
    end
  end
end # class LogStash::Inputs::Lumberjack
