#
# Copyright (c) 2009 RightScale Inc
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

require File.join(File.dirname(__FILE__), 'spec_helper')
require 'tmpdir'

describe RightScale::HA_MQ do

  describe "Identifying" do

    it "should use host and port to uniquely identity broker in AgentIdentity format" do
      RightScale::HA_MQ.identity("localhost", 5672).should == "rs-broker-localhost-5672"
      RightScale::HA_MQ.identity("10.21.102.23", 1234).should == "rs-broker-10.21.102.23-1234"
    end

    it "should obtain host and port from a broker's identity" do
      RightScale::HA_MQ.host("rs-broker-localhost-5672").should == "localhost"
      RightScale::HA_MQ.port("rs-broker-localhost-5672").should == 5672
      RightScale::HA_MQ.host("rs-broker-10.21.102.23-1234").should == "10.21.102.23"
      RightScale::HA_MQ.port("rs-broker-10.21.102.23-1234").should == 1234
    end

    it "should form list of broker identities from specified hosts and ports" do
      RightScale::HA_MQ.identities("11.22.33.44,55.66.77.88", "5672,5674").should ==
        ["rs-broker-11.22.33.44-5672", "rs-broker-55.66.77.88-5674"]
    end

    it "should use default host and port for broker identity if none provided" do
      RightScale::HA_MQ.identities(nil, nil).should == ["rs-broker-localhost-5672"]
    end

    it "should reuse host if there is only one but multiple ports" do
      RightScale::HA_MQ.identities("11.22.33.44", "5672,5674").should ==
        ["rs-broker-11.22.33.44-5672", "rs-broker-11.22.33.44-5674"]
    end

    it "should reuse port if there is only one but multiple hosts" do
      RightScale::HA_MQ.identities("11.22.33.44,55.66.77.88", 5672).should ==
        ["rs-broker-11.22.33.44-5672", "rs-broker-55.66.77.88-5672"]
    end

    it "should not allow mismatched number of hosts and ports" do
      runner = lambda { RightScale::HA_MQ.identities("11.22.33.44,55.66.77.88", "5672,5673,5674") }
      runner.should raise_error(RightScale::Exceptions::Argument)
    end

  end # Identifying

  describe "Initializing" do

    before(:each) do
      @serializer = flexmock("Serializer")
      @connection = flexmock("connection", :connection_status => true).by_default
      flexmock(AMQP).should_receive(:connect).and_return(@connection).by_default
      @mq = flexmock("mq", :connection => @connection)
      flexmock(MQ).should_receive(:new).with(@connection).and_return(@mq).by_default
      flexmock(RightScale::RightLinkLog).should_receive(:info).by_default
    end

    it "should create a broker with AMQP connection for default host and port" do
      ha_mq = RightScale::HA_MQ.new(@serializer)
      ha_mq.brokers.should == [{:index => 0, :mq => @mq, :identity => "rs-broker-localhost-5672", :status => :connected}]
    end

    it "should create AMQP connections for specified hosts and ports and assign index in order of creation" do
      ha_mq = RightScale::HA_MQ.new(@serializer, :host => "11.22.33.44,55.66.77.88", :port => 5672)
      ha_mq.brokers.should == [{:index => 0, :mq => @mq, :identity => "rs-broker-11.22.33.44-5672", :status => :connected},
                               {:index => 1, :mq => @mq, :identity => "rs-broker-55.66.77.88-5672", :status => :connected}]
    end

    it "should log an info message when it creates an AMQP connection" do
      flexmock(RightScale::RightLinkLog).should_receive(:info).with(/Connected to AMQP broker/).twice
      RightScale::HA_MQ.new(@serializer, :host => "11.22.33.44,55.66.77.88", :port => 5672)
    end

    it "should log an error if it fails to create an AMQP connection" do
      flexmock(RightScale::RightLinkLog).should_receive(:info).never
      flexmock(RightScale::RightLinkLog).should_receive(:error).with(/Failed to connect to AMQP broker/).once
      flexmock(MQ).should_receive(:new).with(@connection).and_raise(Exception)
      RightScale::HA_MQ.new(@serializer)
    end

    it "should allow prefetch value to be set for all usable brokers" do
      @mq.should_receive(:prefetch).twice
      ha_mq = RightScale::HA_MQ.new(@serializer, :host => "11.22.33.44,55.66.77.88", :port => 5672)
      ha_mq.prefetch(1)
    end

  end # Initializing

  describe "Subscribing" do

    before(:each) do
      @info = flexmock("info", :ack => true).by_default
      @message = flexmock("message")
      @packet = flexmock("packet", :class => RightScale::Request, :version => 1, :to_s => true).by_default
      @serializer = flexmock("Serializer", :load => @packet).by_default
      @direct = flexmock("direct")
      @bind = flexmock("bind")
      @queue = flexmock("queue", :bind => @bind)
      @connection = flexmock("connection", :connection_status => true).by_default
      flexmock(AMQP).should_receive(:connect).and_return(@connection).by_default
      @mq = flexmock("mq", :queue => @queue, :direct => @direct, :connection => @connection)
      flexmock(MQ).should_receive(:new).with(@connection).and_return(@mq).by_default
      flexmock(RightScale::RightLinkLog).should_receive(:info).by_default
    end

    it "should subscribe queue to exchange" do
      @bind.should_receive(:subscribe).and_yield(@message).once
      ha_mq = RightScale::HA_MQ.new(@serializer)
      ha_mq.subscribe({:name => "queue"}, {:type => :direct, :name => "exchange"}) {|p| p.should == nil}
    end

    it "should subscribe queue to exchange in each usable broker" do
      @bind.should_receive(:subscribe).and_yield(@message).once
      ha_mq = RightScale::HA_MQ.new(@serializer, :host => "11.22.33.44,55.66.77.88")
      ha_mq.brokers[0][:status] = :disconnected
      ha_mq.subscribe({:name => "queue"}, {:type => :direct, :name => "exchange"}) {|p| p.should == nil}
    end

    it "should ack received message if requested" do
      @info.should_receive(:ack).once
      @bind.should_receive(:subscribe).and_yield(@info, @message).once
      ha_mq = RightScale::HA_MQ.new(@serializer)
      ha_mq.subscribe({:name => "queue"}, {:type => :direct, :name => "exchange"},
                      :ack => true) {|p| p.should == nil}
    end

    it "should receive message causing it to be unserialized and logged" do
      flexmock(RightScale::RightLinkLog).should_receive(:info).with(/Connected/).once
      flexmock(RightScale::RightLinkLog).should_receive(:info).with(/RECV/).once
      @serializer.should_receive(:load).with(@message).and_return(@packet).once
      @bind.should_receive(:subscribe).and_yield(@message).once
      ha_mq = RightScale::HA_MQ.new(@serializer)
      ha_mq.subscribe({:name => "queue"}, {:type => :direct, :name => "exchange"},
                      RightScale::Request => nil) {|p| p.class.should == RightScale::Request}
    end

    it "should return identity of brokers that were subscribed to" do
      @bind.should_receive(:subscribe).and_yield(@message)
      ha_mq = RightScale::HA_MQ.new(@serializer, :host => "11.22.33.44,55.66.77.88")
      ids = ha_mq.subscribe({:name => "queue"}, {:type => :direct, :name => "exchange"}) {|p| p.should == nil}
      ids.should == ["rs-broker-11.22.33.44-5672", "rs-broker-55.66.77.88-5672"]
    end

    it "should not unserialize the message if requested" do
      flexmock(RightScale::RightLinkLog).should_receive(:info).with(/Connected/).once
      flexmock(RightScale::RightLinkLog).should_receive(:info).with(/^RECV/).never
      @bind.should_receive(:subscribe).and_yield(@message).once
      ha_mq = RightScale::HA_MQ.new(@serializer)
      ha_mq.subscribe({:name => "queue"}, {:type => :direct, :name => "exchange"}, :no_unserialize => true) do |b, m|
        b[:mq].should == @mq
        m.should == @message
      end
    end

  end # Subscribing

  describe "Receiving" do

    before(:each) do
      @message = flexmock("message")
      @packet = flexmock("packet", :class => RightScale::Request, :version => 1, :to_s => true).by_default
      @serializer = flexmock("Serializer")
      @serializer.should_receive(:load).with(@message).and_return(@packet).once
      @connection = flexmock("connection", :connection_status => true).by_default
      flexmock(AMQP).should_receive(:connect).and_return(@connection).by_default
      @mq = flexmock("mq", :connection => @connection)
      flexmock(MQ).should_receive(:new).with(@connection).and_return(@mq).by_default
      flexmock(RightScale::RightLinkLog).should_receive(:info).by_default
    end

    it "should unserialize the message, log it, and return it" do
      flexmock(RightScale::RightLinkLog).should_receive(:info).with(/Connected/).once
      flexmock(RightScale::RightLinkLog).should_receive(:info).with(/^RECV/).once
      ha_mq = RightScale::HA_MQ.new(@serializer)
      ha_mq.each_usable { |b| ha_mq.receive(b, @message, RightScale::Request => nil).should == @packet }
    end

    it "should log a warning if the message if not of the right type and return nil" do
      flexmock(RightScale::RightLinkLog).should_receive(:warn).with(/^RECV/).once
      ha_mq = RightScale::HA_MQ.new(@serializer)
      ha_mq.each_usable { |b| ha_mq.receive(b, @message).should == nil }
    end

    it "should show the category in the warning message if specified" do
      flexmock(RightScale::RightLinkLog).should_receive(:warn).with(/^RECV.*xxxx/).once
      ha_mq = RightScale::HA_MQ.new(@serializer)
      ha_mq.each_usable { |b| ha_mq.receive(b, @message, RightScale::Result => nil, :category => "xxxx") }
    end

    it "should display version number and broker index in the log" do
      flexmock(RightScale::RightLinkLog).should_receive(:info).with(/Connected/).once
      flexmock(RightScale::RightLinkLog).should_receive(:info).with(/^RECV v1,b0 /).once
      ha_mq = RightScale::HA_MQ.new(@serializer)
      ha_mq.each_usable { |b| ha_mq.receive(b, @message, RightScale::Request => nil) }
    end

    it "should filter the packet display for :info level" do
      flexmock(RightScale::RightLinkLog).should_receive(:info).with(/Connected/).once
      flexmock(RightScale::RightLinkLog).should_receive(:info).with(/^RECV.*TO YOU/).once
      flexmock(RightScale::RightLinkLog).should_receive(:debug).with(/^RECV.*TO YOU/).never
      @packet.should_receive(:to_s).with([:to]).and_return("TO YOU").once
      ha_mq = RightScale::HA_MQ.new(@serializer)
      ha_mq.each_usable { |b| ha_mq.receive(b, @message, RightScale::Request => [:to]) }
    end

    it "should not filter the packet display for :debug level" do
      flexmock(RightScale::RightLinkLog).should_receive(:level).and_return(:debug)
      flexmock(RightScale::RightLinkLog).should_receive(:info).with(/Connected/).once
      flexmock(RightScale::RightLinkLog).should_receive(:info).with(/^RECV.*ALL/).never
      flexmock(RightScale::RightLinkLog).should_receive(:debug).with(/^RECV.*ALL/).once
      @packet.should_receive(:to_s).with(nil).and_return("ALL").once
      ha_mq = RightScale::HA_MQ.new(@serializer)
      ha_mq.each_usable { |b| ha_mq.receive(b, @message, RightScale::Request => [:to]) }
    end

    it "should display additional data in log" do
      flexmock(RightScale::RightLinkLog).should_receive(:info).with(/Connected/).once
      flexmock(RightScale::RightLinkLog).should_receive(:info).with(/^RECV.*More data/).once
      ha_mq = RightScale::HA_MQ.new(@serializer)
      ha_mq.each_usable { |b| ha_mq.receive(b, @message, RightScale::Request => nil, :log_data => "More data") }
    end

  end # Receiving

  describe "Publishing" do

    before(:each) do
      @message = flexmock("message")
      @packet = flexmock("packet", :class => RightScale::Request, :version => 1, :to_s => true).by_default
      @serializer = flexmock("Serializer")
      @connection = flexmock("connection", :connection_status => true).by_default
      flexmock(AMQP).should_receive(:connect).and_return(@connection).by_default
      @direct = flexmock("direct")
      @mq = flexmock("mq", :connection => @connection)
      flexmock(MQ).should_receive(:new).with(@connection).and_return(@mq).by_default
      flexmock(RightScale::RightLinkLog).should_receive(:info).by_default
    end

    it "should serialize message, publish it, and return list of broker identifiers" do
      @serializer.should_receive(:dump).with(@packet).and_return(@message).once
      @mq.should_receive(:direct).with("exchange", :durable => true).and_return(@direct).once
      @direct.should_receive(:publish).with(@message, :persistent => true).once
      ha_mq = RightScale::HA_MQ.new(@serializer)
      ha_mq.publish({:type => :direct, :name => "exchange", :options => {:durable => true}},
        @packet, :persistent => true).should == ["rs-broker-localhost-5672"]
    end

    it "should publish to first connected broker" do
      @serializer.should_receive(:dump).with(@packet).and_return(@message).once
      @mq.should_receive(:direct).with("exchange", {}).and_return(@direct).once
      @direct.should_receive(:publish).with(@message, {}).once
      ha_mq = RightScale::HA_MQ.new(@serializer, :host => "11.22.33.44,55.66.77.88")
      ha_mq.brokers[0][:status] = :disconnected
      ha_mq.publish({:type => :direct, :name => "exchange"}, @packet).should == ["rs-broker-55.66.77.88-5672"]
    end

    it "should publish to all connected brokers if fanout requested" do
      @serializer.should_receive(:dump).with(@packet).and_return(@message).once
      @mq.should_receive(:direct).with("exchange", {}).and_return(@direct).twice
      @direct.should_receive(:publish).with(@message, :fanout => true).twice
      ha_mq = RightScale::HA_MQ.new(@serializer, :host => "11.22.33.44,55.66.77.88")
      ha_mq.publish({:type => :direct, :name => "exchange"}, @packet, :fanout => true).
        should == ["rs-broker-11.22.33.44-5672", "rs-broker-55.66.77.88-5672"]
    end

    it "should log an error if the publish fails" do
      flexmock(RightScale::RightLinkLog).should_receive(:error).with(/Failed to publish to exchange/).once
      @serializer.should_receive(:dump).with(@packet).and_return(@message).once
      @mq.should_receive(:direct).and_raise(Exception)
      @direct.should_receive(:publish).with(@message, {}).never
      ha_mq = RightScale::HA_MQ.new(@serializer)
      runner = lambda { ha_mq.publish({:type => :direct, :name => "exchange"}, @packet) }
      runner.should raise_error(RightScale::Exceptions::IO)
    end

    it "should raise an exception if there are no connected brokers" do
      @serializer.should_receive(:dump).with(@packet).and_return(@message).once
      ha_mq = RightScale::HA_MQ.new(@serializer)
      ha_mq.brokers[0][:status] = :disconnected
      runner = lambda { ha_mq.publish({:type => :direct, :name => "exchange"}, @packet) }
      runner.should raise_error(RightScale::Exceptions::IO)
    end

    it "should not serialize the message if it is already serialized" do
      @serializer.should_receive(:dump).with(@packet).and_return(@message).never
      @mq.should_receive(:direct).with("exchange", {}).and_return(@direct).once
      @direct.should_receive(:publish).with(@message, :no_serialize => true).once
      ha_mq = RightScale::HA_MQ.new(@serializer)
      ha_mq.publish({:type => :direct, :name => "exchange"}, @message, :no_serialize => true)
    end

    it "should log that message is being sent" do
      flexmock(RightScale::RightLinkLog).should_receive(:info).with(/Connected/).once
      flexmock(RightScale::RightLinkLog).should_receive(:info).with(/^SEND/).once
      @serializer.should_receive(:dump).with(@packet).and_return(@message).once
      @mq.should_receive(:direct).with("exchange", {}).and_return(@direct).once
      @direct.should_receive(:publish).with(@message, {}).once
      ha_mq = RightScale::HA_MQ.new(@serializer)
      ha_mq.publish({:type => :direct, :name => "exchange"}, @packet)
    end

    it "should not log a message if requested not to" do
      flexmock(RightScale::RightLinkLog).should_receive(:info).with(/Connected/).once
      flexmock(RightScale::RightLinkLog).should_receive(:info).with(/^SEND/).never
      @serializer.should_receive(:dump).with(@packet).and_return(@message).once
      @mq.should_receive(:direct).with("exchange", {}).and_return(@direct).once
      @direct.should_receive(:publish).with(@message, :no_log => true).once
      ha_mq = RightScale::HA_MQ.new(@serializer)
      ha_mq.publish({:type => :direct, :name => "exchange"}, @packet, :no_log => true)
    end

    it "should display version number and broker index in the log" do
      flexmock(RightScale::RightLinkLog).should_receive(:info).with(/Connected/).once
      flexmock(RightScale::RightLinkLog).should_receive(:info).with(/^SEND v1,b0 /).once
      @serializer.should_receive(:dump).with(@packet).and_return(@message).once
      @mq.should_receive(:direct).with("exchange", {}).and_return(@direct).once
      @direct.should_receive(:publish).with(@message, {}).once
      ha_mq = RightScale::HA_MQ.new(@serializer)
      ha_mq.publish({:type => :direct, :name => "exchange"}, @packet)
    end

    it "should filter the packet display for :info level" do
      flexmock(RightScale::RightLinkLog).should_receive(:info).with(/Connected/).once
      flexmock(RightScale::RightLinkLog).should_receive(:info).with(/^SEND.*TO YOU/).once
      flexmock(RightScale::RightLinkLog).should_receive(:debug).with(/^SEND.*TO YOU/).never
      @packet.should_receive(:to_s).with([:to]).and_return("TO YOU").once
      @serializer.should_receive(:dump).with(@packet).and_return(@message).once
      @mq.should_receive(:direct).with("exchange", {}).and_return(@direct).once
      @direct.should_receive(:publish).with(@message, :log_filter => [:to]).once
      ha_mq = RightScale::HA_MQ.new(@serializer)
      ha_mq.publish({:type => :direct, :name => "exchange"}, @packet, :log_filter => [:to])

    end

    it "should not filter the packet display for :debug level" do
      flexmock(RightScale::RightLinkLog).should_receive(:level).and_return(:debug)
      flexmock(RightScale::RightLinkLog).should_receive(:info).with(/Connected/).once
      flexmock(RightScale::RightLinkLog).should_receive(:info).with(/^SEND.*ALL/).never
      flexmock(RightScale::RightLinkLog).should_receive(:debug).with(/^SEND.*ALL/).once
      @packet.should_receive(:to_s).with(nil).and_return("ALL").once
      @serializer.should_receive(:dump).with(@packet).and_return(@message).once
      @mq.should_receive(:direct).with("exchange", {}).and_return(@direct).once
      @direct.should_receive(:publish).with(@message, :log_filter => [:to]).once
      ha_mq = RightScale::HA_MQ.new(@serializer)
      ha_mq.publish({:type => :direct, :name => "exchange"}, @packet, :log_filter => [:to])
    end
    
    it "should display additional data in log" do
      flexmock(RightScale::RightLinkLog).should_receive(:info).with(/Connected/).once
      flexmock(RightScale::RightLinkLog).should_receive(:info).with(/^SEND.*More data/).once
      @serializer.should_receive(:dump).with(@packet).and_return(@message).once
      @mq.should_receive(:direct).with("exchange", {}).and_return(@direct).once
      @direct.should_receive(:publish).with(@message, :log_data => "More data").once
      ha_mq = RightScale::HA_MQ.new(@serializer)
      ha_mq.publish({:type => :direct, :name => "exchange"}, @packet, :log_data => "More data")
    end

    it "should display RESEND if the message being sent is a retry" do
      flexmock(RightScale::RightLinkLog).should_receive(:info).with(/Connected/).once
      flexmock(RightScale::RightLinkLog).should_receive(:info).with(/^RESEND/).once
      @packet = flexmock("packet", :class => RightScale::Request, :version => 1, :to_s => true, :tries => ["try1"])
      @serializer.should_receive(:dump).with(@packet).and_return(@message).once
      @mq.should_receive(:direct).with("exchange", {}).and_return(@direct).once
      @direct.should_receive(:publish).with(@message, {}).once
      ha_mq = RightScale::HA_MQ.new(@serializer)
      ha_mq.publish({:type => :direct, :name => "exchange"}, @packet)
    end

  end # Publishing

  describe "Deleting" do

    before(:each) do
      @serializer = flexmock("Serializer")
      @connection = flexmock("connection", :connection_status => true).by_default
      flexmock(AMQP).should_receive(:connect).and_return(@connection).by_default
      @queue = flexmock("queue")
      @mq = flexmock("mq", :connection => @connection).by_default
      flexmock(MQ).should_receive(:new).with(@connection).and_return(@mq).by_default
      flexmock(RightScale::RightLinkLog).should_receive(:info).by_default
    end

    it "should delete queue in each usable broker" do
      @queue.should_receive(:delete).once
      @mq.should_receive(:queue).with("queue").and_return(@queue).once
      ha_mq = RightScale::HA_MQ.new(@serializer, :host => "11.22.33.44,55.66.77.88")
      ha_mq.brokers[0][:status] = :disconnected
      ha_mq.delete("queue").should == ["rs-broker-55.66.77.88-5672"]
    end

    it "should log an error if a delete fails for a broker" do
      flexmock(RightScale::RightLinkLog).should_receive(:error).with(/Failed to delete queue/).once
      @mq.should_receive(:queue).and_raise(Exception)
      ha_mq = RightScale::HA_MQ.new(@serializer)
      ha_mq.delete("queue").should == []
    end

  end # Deleting

  describe "Monitoring" do

    before(:each) do
      @info = flexmock("info", :ack => true).by_default
      @message = flexmock("message")
      @packet = flexmock("packet", :class => RightScale::Request, :version => 1, :to_s => true).by_default
      @serializer = flexmock("Serializer", :load => @packet).by_default
      @direct = flexmock("direct")
      @bind = flexmock("bind")
      @queue = flexmock("queue", :bind => @bind)
      @connection = flexmock("connection", :connection_status => true).by_default
      flexmock(AMQP).should_receive(:connect).and_return(@connection).by_default
      @mq = flexmock("mq", :queue => @queue, :direct => @direct, :connection => @connection)
      flexmock(MQ).should_receive(:new).with(@connection).and_return(@mq).by_default
      flexmock(RightScale::RightLinkLog).should_receive(:info).by_default
    end

    it "should give access to each usable broker" do
      @bind.should_receive(:subscribe).and_yield(@message)
      ha_mq = RightScale::HA_MQ.new(@serializer, :host => "11.22.33.44,55.66.77.88")
      indices = []
      ha_mq.each_usable { |b| indices << b[:index] }
      indices.should == [0, 1]
      indices = []
      ha_mq.brokers[0][:status] = :disconnected
      ha_mq.each_usable { |b| indices << b[:index] }
      indices.should == [1]
    end

    it "should provide connection status callback when cross 0/1 connection threshold" do
      @bind.should_receive(:subscribe).and_yield(@message)
      ha_mq = RightScale::HA_MQ.new(@serializer, :host => "11.22.33.44,55.66.77.88")
      connected = 0
      disconnected = 0
      ha_mq.connection_status do |status|
        if status == :connected
          ha_mq.brokers[0][:status].should == :connected ||
          ha_mq.brokers[1][:status].should == :connected
          connected += 1
        elsif status == :disconnected
          ha_mq.brokers[0][:status].should == :disconnected &&
          ha_mq.brokers[1][:status].should == :disconnected
          disconnected += 1
        end
      end
      ha_mq.__send__(:update_status, ha_mq.brokers[0], :disconnected)
      ha_mq.__send__(:update_status, ha_mq.brokers[1], :disconnected)
      ha_mq.__send__(:update_status, ha_mq.brokers[0], :connected)
      ha_mq.__send__(:update_status, ha_mq.brokers[1], :connected)
      connected.should == 1
      disconnected.should == 1
    end

    it "should return identity of connected brokers" do
      ha_mq = RightScale::HA_MQ.new(@serializer, :host => "11.22.33.44,55.66.77.88")
      ha_mq.connected.should == ["rs-broker-11.22.33.44-5672", "rs-broker-55.66.77.88-5672"]
      ha_mq.brokers[0][:status] = :disconnected
      ha_mq.connected.should == ["rs-broker-55.66.77.88-5672"]
      ha_mq.brokers[1][:status] = :closed
      ha_mq.connected.should == []
    end

  end # Monitoring

  describe "Closing" do

    before(:each) do
      @serializer = flexmock("Serializer")
      @connection = flexmock("connection", :connection_status => true).by_default
      flexmock(AMQP).should_receive(:connect).and_return(@connection).by_default
      @mq = flexmock("mq", :connection => @connection, :instance_variable_get => @connection)
      flexmock(MQ).should_receive(:new).with(@connection).and_return(@mq).by_default
      flexmock(RightScale::RightLinkLog).should_receive(:info).by_default
    end

    it "should close all broker connections" do
      @connection.should_receive(:close).twice
      ha_mq = RightScale::HA_MQ.new(@serializer, :host => "11.22.33.44,55.66.77.88")
      ha_mq.close
      ha_mq.brokers[0][:status].should == :closed
      ha_mq.brokers[1][:status].should == :closed
    end

    it "should execute block if given after all connections are closed" do
      @connection.should_receive(:close).twice
      ha_mq = RightScale::HA_MQ.new(@serializer, :host => "11.22.33.44,55.66.77.88")
      ha_mq.close { ha_mq.brokers[0][:status].should == :closed; ha_mq.brokers[1][:status].should == :closed }
    end

  end # Closing

end # RightScale::HA_MQ
