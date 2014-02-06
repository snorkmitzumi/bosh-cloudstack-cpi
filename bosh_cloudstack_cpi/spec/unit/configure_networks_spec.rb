# Copyright (c) 2009-2013 VMware, Inc.
# Copyright (c) 2012 Piston Cloud Computing, Inc.

require "spec_helper"

describe Bosh::CloudStackCloud::Cloud do

  before(:each) do
    @registry = mock_registry
  end

  it "configures the network when using dynamic network" do
    address = double("address")
    server = double("server", :id => "i-test", :name => "i-test", :addresses => [address], :zone_id => 'foobar-1a')
    security_group = double("security_groups", :name => "default")

    server.should_receive(:security_groups).and_return([security_group])

    cloud = mock_cloud do |compute|
      compute.servers.should_receive(:get).with("i-test").and_return(server)
      compute.zones.should_receive(:get).with("foobar-1a").and_return(compute.zones[0])
    end
    address.should_receive(:ip_address).and_return("10.10.10.1")

    network_spec = { "net_a" => dynamic_network_spec }
    old_settings = { "foo" => "bar", "networks" => network_spec }
    new_settings = { "foo" => "bar", "networks" => network_spec }

    @registry.should_receive(:read_settings).with("i-test").and_return(old_settings)
    @registry.should_receive(:update_settings).with("i-test", new_settings)

    cloud.configure_networks("i-test", network_spec)
  end

  it "configures the network when using vip network" do
    address = double("address", :id => "i-test", :virtual_machine_id => nil)
    server = double("server", :id => "i-test", :name => "i-test", :addresses => [address], :zone_id => 'foobar-2a')
    security_group = double("security_groups", :name => "default")

    server.should_receive(:security_groups).and_return([security_group])
    address.should_receive(:ip_address).and_return("10.10.10.1")
    server.should_receive(:nics).and_return([{'id' => 'i-test', 'networkid' => 'i-test'}])

    nat_params={
        :ip_address_id => address.id,
        :virtual_machine_id => server.id,
        :network_id => "i-test",
    }

    nat = double("nat")
    nat.should_receive(:enable)

    cloud = mock_cloud do |compute|
      compute.servers.should_receive(:get).with("i-test").and_return(server)
      compute.zones.should_receive(:get).with("foobar-2a").and_return(compute.zones[1])
      compute.ipaddresses.should_receive(:find).and_return(address)
      compute.nats.should_receive(:new).with(nat_params).and_return(nat)
    end

    network_spec = { "network_a" => dynamic_network_spec, "network_b" => vip_network_spec }
    old_settings = { "foo" => "bar", "networks" => network_spec }
    new_settings = { "foo" => "bar", "networks" => network_spec }

    @registry.should_receive(:read_settings).with("i-test").and_return(old_settings)
    @registry.should_receive(:update_settings).with("i-test", new_settings)

    cloud.configure_networks("i-test", combined_network_spec)
  end

  it "configures network when using vip network with IP already associated to server" do
    address = double("address", :id => "i-test", :virtual_machine_id => "i-test")
    server = double("server", :id => "i-test", :name => "i-test", :addresses => [address], :zone_id => 'foobar-2a')
    security_group = double("security_groups", :name => "default")

    server.should_receive(:security_groups).and_return([security_group])
    address.should_receive(:ip_address).and_return("10.10.10.1")
    server.should_receive(:nics).and_return([{'id' => 'i-test', 'networkid' => 'i-test'}])

    nat = double("nat")
    nat.should_receive(:enable)
    nat_job = double("nat_job")
    nat.should_receive(:disable).and_return(nat_job)
    nat_job.should_receive(:wait_for).and_return(cost_time_spec)

    nat_params1 = {
        :ip_address_id => address.id,
    }

    nat_params2 = {
        :ip_address_id => address.id,
        :virtual_machine_id => server.id,
        :network_id => "i-test"
    }

    cloud = mock_cloud do |compute|
      compute.servers.should_receive(:get).with("i-test").and_return(server)
      compute.zones.should_receive(:get).with("foobar-2a").and_return(compute.zones[1])
      compute.ipaddresses.should_receive(:find).and_return(address)
      compute.nats.should_receive(:new).with(nat_params1).and_return(nat)
      compute.nats.should_receive(:new).with(nat_params2).and_return(nat)
    end

    network_spec = { "network_a" => dynamic_network_spec, "network_b" => vip_network_spec }
    old_settings = { "foo" => "bar", "networks" => network_spec }
    new_settings = { "foo" => "bar", "networks" => network_spec }

    @registry.should_receive(:read_settings).with("i-test").and_return(old_settings)
    @registry.should_receive(:update_settings).with("i-test", new_settings)

    cloud.configure_networks("i-test", combined_network_spec)
  end

  it "throw an exception while public IP not found" do
    address = double("address", :id => "i-test", :virtual_machine_id => nil)
    server = double("server", :id => "i-test", :name => "i-test", :addresses => [address], :zone_id => 'foobar-2a')
    security_group = double("security_groups", :name => "default")

    server.should_receive(:security_groups).and_return([security_group])
    address.should_receive(:ip_address).and_return("10.10.10.1")

    cloud = mock_cloud do |compute|
      compute.servers.should_receive(:get).with("i-test").and_return(server)
      compute.zones.should_receive(:get).with("foobar-2a").and_return(compute.zones[1])
      compute.ipaddresses.should_receive(:find).and_return(nil)
    end

    expect {
      cloud.configure_networks("i-test", combined_network_spec)
    }.to raise_error Bosh::Clouds::CloudError
  end

  it "forces recreation when security groups differ" do
    address = double("address")
    server = double("server", :id => "i-test", :name => "i-test", :addresses => [address], :zone_id => 'foobar-2a')
    security_group = double("security_groups", :name => "newgroups")

    server.should_receive(:security_groups).and_return([security_group])

    cloud = mock_cloud do |compute|
      compute.servers.should_receive(:get).with("i-test").and_return(server)
      compute.zones.should_receive(:get).with("foobar-2a").and_return(compute.zones[1])
    end

    expect {
      cloud.configure_networks("i-test", combined_network_spec)
    }.to raise_error Bosh::Clouds::NotSupported
  end

  it "adds floating ip to the server for vip network" do
    address = double("address", :id => "i-test", :virtual_machine_id => nil)
    server = double("server", :id => "i-test", :name => "i-test", :addresses => [address], :zone_id => 'foobar-2a')
    security_group = double("security_groups", :name => "default")

    server.should_receive(:security_groups).and_return([security_group])
    address.should_receive(:ip_address).and_return("10.10.10.1")
    server.should_receive(:nics).and_return([{'id' => 'i-test', 'networkid' => 'i-test'}])

    nat_params={
        :ip_address_id => address.id,
        :virtual_machine_id => server.id,
        :network_id => "i-test",
    }

    nat = double("nat")
    nat.should_receive(:enable)

    cloud = mock_cloud do |compute|
      compute.servers.should_receive(:get).with("i-test").and_return(server)
      compute.zones.should_receive(:get).with("foobar-2a").and_return(compute.zones[1])
      compute.ipaddresses.should_receive(:find).and_return(address)
      compute.nats.should_receive(:new).with(nat_params).and_return(nat)
    end

    old_settings = { "foo" => "bar", "networks" => { "network_a" => dynamic_network_spec } }
    new_settings = { "foo" => "bar", "networks" => combined_network_spec }

    @registry.should_receive(:read_settings).with("i-test").and_return(old_settings)
    @registry.should_receive(:update_settings).with("i-test", new_settings)

    cloud.configure_networks("i-test", combined_network_spec)
  end

  it "removes floating ip from the server if vip network is gone" do
    address = double("address", :id => "i-test", :virtual_machine_id => nil)
    server = double("server", :id => "i-test", :name => "i-test", :addresses => [address], :zone_id => 'foobar-2a')
    security_group = double("security_groups", :name => "default")

    server.should_receive(:security_groups).and_return([security_group])
    address.should_receive(:ip_address).and_return("10.10.10.1")

    cloud = mock_cloud do |compute|
      compute.servers.should_receive(:get).with("i-test").and_return(server)
      compute.zones.should_receive(:get).with("foobar-2a").and_return(compute.zones[1])
    end

    old_settings = { "foo" => "bar", "networks" => combined_network_spec }
    new_settings = { "foo" => "bar", "networks" => { "network_a" => dynamic_network_spec } }

    @registry.should_receive(:read_settings).with("i-test").and_return(old_settings)
    @registry.should_receive(:update_settings).with("i-test", new_settings)

    cloud.configure_networks("i-test", "network_a" => dynamic_network_spec)
  end

  def mock_cloud_advanced
    mock_cloud do |compute|
      compute.zones.stub(:get).with("foobar-2a").and_return(compute.zones[1])
      compute.stub_chain(:servers, :get).with("i-test").and_return(
          double("server", :id => "i-test", :name => "i-test", :addresses => [double("address")], :zone_id => 'foobar-2a'))
    end
  end

  it "performs network sanity check" do
    expect {
      mock_cloud_advanced.configure_networks("i-test",
                                    "net_a" => vip_network_spec)
    }.to raise_error(Bosh::Clouds::CloudError,
                     "At least one dynamic network should be defined")

    expect {
      mock_cloud_advanced.configure_networks("i-test",
                                    "net_a" => vip_network_spec,
                                    "net_b" => vip_network_spec)
    }.to raise_error(Bosh::Clouds::CloudError, /More than one vip network/)

    expect {
      mock_cloud_advanced.configure_networks("i-test",
                                    "net_a" => dynamic_network_spec,
                                    "net_b" => dynamic_network_spec)
    }.to raise_error(Bosh::Clouds::CloudError, /Must have exactly one dynamic network per instance/)

    expect {
      mock_cloud_advanced.configure_networks("i-test",
                                    "net_a" => { "type" => "foo" })
    }.to raise_error(Bosh::Clouds::CloudError, /Invalid network type `foo'/)
  end

end
