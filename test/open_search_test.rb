require 'minitest/autorun'
require 'socket'
require 'net/ldap'
require_relative '../lib/lom'

# Searches left early on a connection opened by LOM.open must not leave
# their unread results on that connection.
class OpenSearchTest < Minitest::Test
    ENTRIES = 50

    # Minimal LDAP server: accepts any bind, answers any search
    # with ENTRIES entries under ou=People,dc=x
    class FakeServer
        attr_reader :port, :connections

        def initialize
            @srv         = TCPServer.new('127.0.0.1', 0)
            @port        = @srv.addr[1]
            @connections = 0
            @thread      = Thread.new { loop { serve(@srv.accept) } }
        end

        def stop
            @thread.kill
            @srv.close
        end

        private

        def serve(sock)
            @connections += 1
            Thread.new do
                sock.extend(Net::BER::BERParser)
                while (req = sock.read_ber(Net::LDAP::AsnSyntax))
                    id, op = req
                    case op.ber_identifier
                    when 0x60 then reply(sock, id, 1)
                    when 0x63
                        ENTRIES.times {|i| entry(sock, id, "u#{i}") }
                        reply(sock, id, 5)
                    else break
                    end
                end
            rescue IOError, SystemCallError
            ensure
                sock.close
            end
        end

        def reply(sock, id, tag)
            sock.write [ id.to_ber,
                         [ 0.to_ber_enumerated, ''.to_ber, ''.to_ber ]
                             .to_ber_appsequence(tag) ].to_ber_sequence
        end

        def entry(sock, id, uid)
            attrs = [ [ 'uid'.to_ber, [ uid.to_ber ].to_ber_set ]
                          .to_ber_sequence ].to_ber_sequence
            sock.write [ id.to_ber,
                         [ "uid=#{uid},ou=People,dc=x".to_ber, attrs ]
                             .to_ber_appsequence(4) ].to_ber_sequence
        end
    end

    class Person
        extend LOM::Mapper
        ldap_branch 'ou=People,dc=x'
        ldap_prefix :uid
        ldap_attrs  '*'
        ldap_from   { { uid: first(:uid) } }

        attr_reader :uid
        def initialize(h) = @uid = h[:uid]
    end

    def setup
        Thread.current[:__lom_lh]     = nil
        Thread.current[:__lom_opened] = nil
        @server = FakeServer.new
        port    = @server.port
        LOM.lh  = -> {
            Net::LDAP.new(host: '127.0.0.1', port: port).tap {|h|
                h.define_singleton_method(:paged_searches_supported?) { false }
            }
        }
    end

    def teardown
        LOM.lh = nil
        @server.stop
    end

    # Messages read but not consumed on the opened connection
    def unread
        conn = LOM.lh.instance_variable_get(:@open_connection)
        conn.send(:message_queue).values.sum(&:size)
    end

    def test_first_does_not_leave_unread_entries
        LOM.open {
            assert_equal 'u0', Person.first.uid
            assert_equal ENTRIES, Person.all.size
            assert_equal 0, unread
        }
    end

    def test_paged_does_not_leave_unread_entries
        LOM.open {
            assert_equal %w[u2 u3], Person.paginate(2, 2).all.map(&:uid)
            assert_equal ENTRIES, Person.all.size
            assert_equal 0, unread
        }
    end

    def test_early_exit_inside_running_search
        LOM.open {
            seen  = 0
            inner = []
            Person.each {|p|
                seen += 1
                inner << Person.first.uid if seen <= 2
            }
            assert_equal ENTRIES, seen
            assert_equal %w[u0 u0], inner
            assert_equal ENTRIES, Person.all.size
            assert_equal 0, unread
        }
    end

    def test_exception_does_not_leave_unread_entries
        LOM.open {
            assert_raises(RuntimeError) { Person.each { raise 'app' } }
            assert_equal ENTRIES, Person.all.size
            assert_equal 0, unread
        }
    end

    def test_without_open_nothing_changes
        assert_equal 'u0', Person.first.uid
        assert_equal ENTRIES, Person.all.size
    end
end
