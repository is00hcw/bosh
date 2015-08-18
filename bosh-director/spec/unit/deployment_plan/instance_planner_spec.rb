require 'spec_helper'

describe Bosh::Director::DeploymentPlan::InstancePlanner do
  subject(:instance_planner) {Bosh::Director::DeploymentPlan::InstancePlanner.new(logger, instance_repo)}
  let(:logger) { instance_double(Logger, debug: nil) }
  let(:instance_repo) { class_double(Bosh::Director::DeploymentPlan::Instance) }
  let(:deployment) { instance_double(Bosh::Director::DeploymentPlan::Planner) }
  let(:az) do
    Bosh::Director::DeploymentPlan::AvailabilityZone.new({
        'name' => 'foo-az',
        'cloud_properties' => {}
      })
  end
  let(:job) { instance_double(Bosh::Director::DeploymentPlan::Job, name: 'foo-job', availability_zones: [az]) }
  let(:desired_instance) { Bosh::Director::DeploymentPlan::DesiredInstance.new(job, nil, deployment) }
  let(:tracer_instance) { instance_double(Bosh::Director::DeploymentPlan::Instance) }

  describe '#plan_job_instances' do
    it 'creates instance plans for new instances with no az' do
      job = instance_double(Bosh::Director::DeploymentPlan::Job, name: 'foo-job', availability_zones: [])
      existing_instance = Bosh::Director::Models::Instance.make(job: 'foo-job', index: 0)
      existing_instances = [existing_instance]
      existing_instance_state = {'foo' => 'bar'}
      states_by_existing_instance = {existing_instance => existing_instance_state}

      allow(instance_repo).to receive(:fetch_existing).with(desired_instance, existing_instance_state, 0, logger) { tracer_instance }

      instance_plans = instance_planner.plan_job_instances(job, [desired_instance], existing_instances, states_by_existing_instance)

      expect(instance_plans.count).to eq(1)
      existing_instance_plan = instance_plans.first

      expect(existing_instance_plan.new?).to eq(false)
      expect(existing_instance_plan.obsolete?).to eq(false)
      expect(existing_instance_plan.desired_instance).to eq(desired_instance)
      expect(existing_instance_plan.instance).to eq(tracer_instance)
      expect(existing_instance_plan.existing_instance).to eq(existing_instance)
    end

    it 'creates instance plans for existing instances' do
      existing_instance = Bosh::Director::Models::Instance.make(job: 'foo-job', index: 0, availability_zone: az.name)
      existing_instances = [existing_instance]
      existing_instance_state = {'foo' => 'bar'}
      states_by_existing_instance = {existing_instance => existing_instance_state}

      allow(instance_repo).to receive(:fetch_existing).with(desired_instance, existing_instance_state, 0, logger) { tracer_instance }

      instance_plans = instance_planner.plan_job_instances(job, [desired_instance], existing_instances, states_by_existing_instance)

      expect(instance_plans.count).to eq(1)
      existing_instance_plan = instance_plans.first

      expect(existing_instance_plan.new?).to eq(false)
      expect(existing_instance_plan.obsolete?).to eq(false)
      expect(existing_instance_plan.desired_instance).to eq(desired_instance)
      expect(existing_instance_plan.instance).to eq(tracer_instance)
      expect(existing_instance_plan.existing_instance).to eq(existing_instance)
    end

    it 'creates instance plans for new instances' do
      existing_instances = []
      states_by_existing_instance = {}

      allow(instance_repo).to receive(:create).with(desired_instance, 0, logger) { tracer_instance }

      instance_plans = instance_planner.plan_job_instances(job, [desired_instance], existing_instances, states_by_existing_instance)

      expect(instance_plans.count).to eq(1)
      new_instance_plan = instance_plans.first

      expect(new_instance_plan.new?).to eq(true)
      expect(new_instance_plan.obsolete?).to eq(false)
      expect(new_instance_plan.desired_instance).to eq(desired_instance)
      expect(new_instance_plan.instance).to eq(tracer_instance)
      expect(new_instance_plan.existing_instance).to be_nil
      expect(new_instance_plan).to be_new
    end

    it 'creates instance plans for new, existing and obsolete instances' do
      out_of_typical_range_index = 77
      auto_picked_index = 0
      undesired_az = Bosh::Director::DeploymentPlan::AvailabilityZone.new({
          'name' => 'old-az',
          'cloud_properties' => {}
        })
      desired_instances = [desired_instance, Bosh::Director::DeploymentPlan::DesiredInstance.new(job, nil, deployment)]

      undesired_existing_instance_model = Bosh::Director::Models::Instance.make(job: 'foo-job', index: auto_picked_index, availability_zone: undesired_az.name)
      undesired_existing_instance_state = {'foo' => 'bar'}

      desired_existing_instance_model = Bosh::Director::Models::Instance.make(job: 'foo-job', index: out_of_typical_range_index, availability_zone: az.name)
      desired_existing_instance_state = {'bar' => 'baz'}

      states_by_existing_instance = {
        undesired_existing_instance_model => undesired_existing_instance_state,
        desired_existing_instance_model => desired_existing_instance_state,
      }

      existing_instances = [undesired_existing_instance_model, desired_existing_instance_model]

      expected_desired_instance = Bosh::Director::DeploymentPlan::DesiredInstance.new(job, nil, deployment, az, desired_existing_instance_model)

      allow(instance_repo).to receive(:fetch_existing).with(expected_desired_instance, desired_existing_instance_state, out_of_typical_range_index, logger) do
        instance_double(Bosh::Director::DeploymentPlan::Instance)
      end

      allow(instance_repo).to receive(:create).with(desired_instances[1], auto_picked_index, logger) { instance_double(Bosh::Director::DeploymentPlan::Instance) }
      allow(instance_repo).to receive(:fetch_obsolete).with(undesired_existing_instance_model, logger) {tracer_instance}

      instance_plans = instance_planner.plan_job_instances(job, desired_instances, existing_instances, states_by_existing_instance)

      expect(instance_plans.count).to eq(3)

      existing_instance_plan = instance_plans.first
      expect(existing_instance_plan.new?).to eq(false)
      expect(existing_instance_plan.obsolete?).to eq(false)

      new_instance_plan = instance_plans[1]
      expect(new_instance_plan.new?).to eq(true)
      expect(new_instance_plan.obsolete?).to eq(false)

      obsolete_instance_plan = instance_plans[2]
      expect(obsolete_instance_plan.new?).to eq(false)
      expect(obsolete_instance_plan.obsolete?).to eq(true)
      expect(obsolete_instance_plan.desired_instance).to be_nil
      expect(obsolete_instance_plan.existing_instance).to eq(undesired_existing_instance_model)
      expect(obsolete_instance_plan.instance).to eq(tracer_instance)
    end
  end

  describe '#plan_obsolete_jobs' do
    it 'returns instance plans for each job' do
      existing_instance_thats_desired = Bosh::Director::Models::Instance.make(job: 'foo-job', index: 0)
      existing_instance_thats_obsolete = Bosh::Director::Models::Instance.make(job: 'bar-job', index: 1)

      allow(instance_repo).to receive(:fetch_obsolete).
          with(existing_instance_thats_obsolete, logger) { tracer_instance }

      existing_instances = [existing_instance_thats_desired, existing_instance_thats_obsolete]
      instance_plans = instance_planner.plan_obsolete_jobs([job], existing_instances)

      expect(instance_plans.count).to eq(1)

      obsolete_instance_plan = instance_plans.first
      expect(obsolete_instance_plan.instance).to eq(tracer_instance)
      expect(obsolete_instance_plan.desired_instance).to be_nil
      expect(obsolete_instance_plan.existing_instance).to eq(existing_instance_thats_obsolete)
      expect(obsolete_instance_plan).to be_obsolete
    end
  end
end
