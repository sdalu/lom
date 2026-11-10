require 'minitest/autorun'
require 'net/ldap'
require_relative '../lib/lom'

class HandlerTest < Minitest::Test
    # Connection double: counts connections, records bind and close
    class FakeConnection
        attr_reader :closed

        def initialize(bind_code) = @bind_code = bind_code
        def bind(_auth)           = @bind_code
        def close                 = @closed = true
    end

    # Net::LDAP handler whose connections are FakeConnection
    def fake_ldap(bind_code: Net::LDAP::ResultCodeSuccess, fail: false)
        ldap  = Net::LDAP.new
        conns = []
        ldap.define_singleton_method(:new_connection) {
            raise Net::LDAP::ConnectionError, [] if fail
            FakeConnection.new(bind_code).tap { conns << it }
        }
        ldap.define_singleton_method(:connections) { conns }
        ldap.define_singleton_method(:opened?) {
            !@open_connection.nil?
        }
        ldap
    end

    def setup
        Thread.current[:__lom_lh]     = nil
        Thread.current[:__lom_opened] = nil
    end

    def teardown
        LOM.lh = nil
    end

    def test_plain_handler_is_returned_unchanged
        h = Net::LDAP.new
        LOM.lh = h
        assert_same h, LOM.lh
        assert_same h, Thread.new { LOM.lh }.value
    end

    def test_global_fallback_without_lh_constant
        h   = Net::LDAP.new
        $lh = h
        assert_same h, LOM.lh
    ensure
        $lh = nil
    end

    def test_callable_is_called_once_per_thread
        calls  = 0
        LOM.lh = -> { calls += 1 ; Net::LDAP.new }
        a, b   = LOM.lh, LOM.lh
        assert_same a, b
        c      = Thread.new { LOM.lh }.value
        refute_same a, c
        assert_equal 2, calls
    end

    def test_callable_is_called_once_per_fiber
        LOM.lh = -> { Net::LDAP.new }
        refute_same LOM.lh, Fiber.new { LOM.lh }.resume
    end

    def test_distinct_factories_give_distinct_handlers
        f1, f2 = -> { Net::LDAP.new }, -> { Net::LDAP.new }
        refute_same LOM.materialize_lh(f1), LOM.materialize_lh(f2)
        assert_same LOM.materialize_lh(f1), LOM.materialize_lh(f1)
    end

    def test_mapper_resolves_callable
        LOM.lh = -> { Net::LDAP.new }
        klass  = Class.new { extend LOM::Mapper }
        assert_same LOM.lh, klass.lh
        f      = -> { Net::LDAP.new }
        klass.lh = f
        assert_same LOM.materialize_lh(f), klass.lh
        refute_same LOM.lh, klass.lh
    end

    def test_open_keeps_one_connection_for_the_block
        h      = fake_ldap
        LOM.lh = -> { h }
        r = LOM.open {
            assert h.opened?
            LOM.open { assert h.opened? }       # nesting reuses it
            :value
        }
        assert_equal :value, r
        assert_equal 1, h.connections.size
        assert h.connections.first.closed
        refute h.opened?
    end

    def test_open_with_plain_handler_does_not_open
        h      = fake_ldap
        LOM.lh = h
        assert_equal :value, LOM.open { refute h.opened? ; :value }
        assert_empty h.connections
    end

    def test_open_falls_back_on_bind_failure
        h      = fake_ldap(bind_code: Net::LDAP::ResultCodeInvalidCredentials)
        LOM.lh = -> { h }
        runs   = 0
        assert_equal :value, LOM.open { runs += 1 ; refute h.opened? ; :value }
        assert_equal 1, runs
        assert h.connections.first.closed
    end

    def test_open_falls_back_on_connection_failure
        h      = fake_ldap(fail: true)
        LOM.lh = -> { h }
        runs   = 0
        assert_equal :value, LOM.open { runs += 1 ; :value }
        assert_equal 1, runs
    end

    def test_open_propagates_block_errors_without_rerunning
        h      = fake_ldap
        LOM.lh = -> { h }
        runs   = 0
        assert_raises(Net::LDAP::Error) {
            LOM.open { runs += 1 ; raise Net::LDAP::Error, 'app' }
        }
        assert_equal 1, runs
        refute h.opened?
        assert_raises(RuntimeError) { LOM.open { raise 'app' } }
        refute h.opened?
    end
end
