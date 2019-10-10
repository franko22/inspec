require "functional/helper"

describe "waivers" do
  include FunctionalHelper

  parallelize_me! # 10s -> 2s w/ N=15

  let(:waivers_profiles_path) { "#{profile_path}/waivers" }
  let(:run_result)            { run_inspec_process(cmd, json: true) }
  let(:controls_by_id)        { run_result.payload.json.dig("profiles", 0, "controls").map { |c| [c["id"], c] }.to_h }
  let(:cmd)                   { "exec #{waivers_profiles_path}/#{profile_name} --input-file #{waivers_profiles_path}/#{profile_name}/files/#{waiver_file}" }

  def assert_test_outcome(expected, control_id)
    assert_equal expected, controls_by_id.dig(control_id, "results", 0, "status")
  end

  def assert_stringy(s)
    assert_kind_of String, s
    refute_empty s
  end

  def waiver_data(control_id)
    controls_by_id.dig(control_id, "waiver_data")
  end

  def assert_waiver_annotation(control_id)
    act = waiver_data control_id

    # extract data from control_id
    expiry    = !!(control_id !~ /no_expiry/)
    in_past   = !!(control_id =~ /in_past/)
    in_future = !!(control_id =~ /in_future/)
    ran       = !!(control_id !~ /not_ran/)

    # higher logic
    waived      = (!expiry && !ran) || (expiry && !ran && in_future)
    # TODO: wasn't message was originally specced as being optional?
    has_message = expiry && !ran && in_past

    assert_instance_of Hash, act

    assert_stringy        act["justification"] # TODO: optional?
    assert_equal ran,     act["run"]
    assert_equal waived,  act["skipped_due_to_waiver"]
    assert_stringy        act["message"] if     has_message
    assert_equal "",      act["message"] unless has_message
  end

  def refute_waiver_annotation(control_id)
    act = waiver_data control_id
    assert_instance_of Hash, act
    assert_empty act
  end

  def assert_skip_message(yea, nay)
    msg = controls_by_id.dig("01_only_if", "results", 0, "skip_message")
    assert_includes msg, yea
    refute_includes msg, nay
  end

  describe "a fully pre-slugged control file" do
    let(:profile_name) { "basic" }
    let(:waiver_file) { "waivers.yaml" }

    # rubocop:disable Layout/AlignHash
    {
      "01_not_waivered_passes"                          => "passed",
      "02_not_waivered_fails"                           => "failed",
      "03_waivered_no_expiry_ran_passes"                => "passed",
      "04_waivered_no_expiry_ran_fails"                 => "failed",
      "05_waivered_no_expiry_not_ran"                   => "skipped",
      "06_waivered_expiry_in_past_ran_passes"           => "passed",
      "07_waivered_expiry_in_past_ran_fails"            => "failed",
      "08_waivered_expiry_in_past_not_ran"              => "passed",
      "09_waivered_expiry_in_future_ran_passes"         => "passed",
      "10_waivered_expiry_in_future_ran_fails"          => "failed",
      "11_waivered_expiry_in_future_not_ran"            => "skipped",
    }.each do |control_id, expected|
      it "has all of the expected outcomes #{control_id}" do
        assert_test_outcome expected, control_id

        if control_id !~ /not_waivered/
          assert_waiver_annotation control_id
        else
          refute_waiver_annotation control_id
        end
      end
    end
  end

  describe "an inherited profile" do
    let(:profile_name) { "waiver-wrapper" }
    let(:waiver_file) { "waivers.yaml" }
    it "should set the data in the child but be empty in the wrapper" do
      json = run_result.payload.json
      child_profile = json["profiles"].detect { |p| p["name"] == "waiver-child" }
      child_waiver_data = child_profile.dig("controls", 0, "waiver_data")
      assert_instance_of Hash, child_waiver_data
      refute_empty child_waiver_data
      expected_child_waiver_data = {
        "run" => false,
        "justification" => "I said so",
        "skipped_due_to_waiver" => true,
        "message" => "",
      }
      assert_equal expected_child_waiver_data, child_waiver_data

      wrapper_profile = json["profiles"].detect { |p| p["name"] == "waiver-wrapper" }
      wrapper_waiver_data = wrapper_profile.dig("controls", 0, "waiver_data")
      assert_instance_of Hash, wrapper_waiver_data
      assert_empty wrapper_waiver_data
    end
  end

  # describe "a profile whose control ids require transformation"

  describe "a waiver file with invalid dates" do
    let(:profile_name) { "short" }
    let(:waiver_file) { "bad-date.yaml" }
    it "gracefully errors" do
      result = run_result
      assert_includes "ERROR",    result.stdout # the error level
      assert_includes "01_small", result.stdout # the offending control ID
      assert_includes "never",    result.stdout # The bad value
      assert_equal 1, result.exit_status
    end
  end

  describe "waivers and only_if" do
    let(:profile_name) { "only_if" }

    describe "when an only_if is used with no waiver" do
      let(:waiver_file) { "empty.yaml" }
      it "skips the control with an only_if message" do
        assert_skip_message "due to only_if", "waiver"
      end
    end

    describe "when both a skipping waiver and an only_if are present" do
      let(:waiver_file) { "waiver.yaml" }
      it "skips the control with a waiver message" do
        assert_skip_message "waiver", "due to only_if"
      end
    end
  end
end
