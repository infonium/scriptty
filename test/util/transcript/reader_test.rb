# = Tests for ScripTTY::Util::Transcript::Reader
# Copyright (C) 2010  Infonium Inc.
#
# This file is part of ScripTTY.
#
# ScripTTY is free software: you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published
# by the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# ScripTTY is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with ScripTTY.  If not, see <http://www.gnu.org/licenses/>.

require File.dirname(__FILE__) + "/../../test_helper.rb"
require 'scriptty/util/transcript/reader'

class TranscriptReaderTest < Test::Unit::TestCase
  def test_basic
    input_lines = <<-'EOF'.split("\n").map{|line| line.strip}
      [0.000] * "Informational message" "with argument" "\377"
      [0.000] Copen "10.0.0.5" "55555"
      [0.000] Sopen "10.0.0.1" "1234"
      [0.001] C "alice\211\0010"
      [0.001] S "bob\042"
      [2.500] Cp "foo" "arg"
      [2.900] Sp "." "arg"
      [3.000] Sp "ESC" "\033"
      [4.000] Cx "disconnect"
      [5.000] Sx "disconnect"
      [5.000] Sx
      [5] Cx
    EOF
    expected = [
      [0.0, :info, ["Informational message", "with argument", "\xff"]],
      [0.0, :client_open, ["10.0.0.5", 55555]],
      [0.0, :server_open, ["10.0.0.1", 1234]],
      [0.001, :from_client, ["alice\x89\x01\x30"]],
      [0.001, :from_server, ["bob\x22"]],
      [2.5, :client_parsed, ["foo", "arg"]],
      [2.9, :server_parsed, [".", "arg"]],
      [3.0, :server_parsed, ["ESC", "\x1b"]],
      [4.0, :client_close, ["disconnect"]],
      [5.0, :server_close, ["disconnect"]],
      [5.0, :server_close, []],
      [5.0, :client_close, []],
    ]
    reader = ScripTTY::Util::Transcript::Reader.new
    actual = input_lines.map{|line| reader.parse_line(line) }
    assert_equal expected, actual
  end

  def test_bad_inputs
    # Each line of the following must fail to parse
    input_lines = <<-'EOF'.split("\n").map{|line| line.strip}
      [0.000] * "Lone backslash" "\"
      [0.000] * "Bad octal value" "\400"
      [0.100] * "No quotes" foo
      [0.200] $ "Unknown type"
      [0.200] Copen "bad port" "10abc"
      [0.200] Sopen "bad port" "10abc"
      [0.300] * "Non-printableASCII characters" "Café"
      [0.400]  Cx "too much whitespace"
      * "No timestamp"
      [] * "Empty timestamp"
      [5.5.5] "multiple decimals in timestamp"
    EOF
    reader = ScripTTY::Util::Transcript::Reader.new
    input_lines.each do |line|
      assert_raise(ArgumentError, line.inspect) do
        reader.parse_line(line)
      end
    end

    # Every escape, as encoded by ScripTTY::Util::Transcript::Writer, should
    # parse correctly.
    def test_escapes
      input = '[99.000] S "\000\001\002\003\004\005\006\007'
      input += '\010\011\012\013\014\015\016\017\020\021\022\023\024\025\026\027'
      input += '\030\031\032\033\034\035\036\037 !\042#$%&' + "'"
      input += '()*+,-./0123456789:;<=>?'
      input += '@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\134]^_'
      input += '`abcdefghijklmnopqrstuvwxyz{|}~\177'
      input += '\200\201\202\203\204\205\206\207\210\211\212\213\214\215\216\217'
      input += '\220\221\222\223\224\225\226\227\230\231\232\233\234\235\236\237'
      input += '\240\241\242\243\244\245\246\247\250\251\252\253\254\255\256\257'
      input += '\260\261\262\263\264\265\266\267\270\271\272\273\274\275\276\277'
      input += '\300\301\302\303\304\305\306\307\310\311\312\313\314\315\316\317'
      input += '\320\321\322\323\324\325\326\327\330\331\332\333\334\335\336\337'
      input += '\340\341\342\343\344\345\346\347\350\351\352\353\354\355\356\357'
      input += '\360\361\362\363\364\365\366\367\370\371\372\373\374\375\376\377'
      input += "\"\n"
      reader = ScripTTY::Util::Transcript::Reader.new
      timestamp, type, args = reader.parse_line(input)
      assert_equal 99.0, timestamp
      assert_equal type, :from_server
      assert_equal args, [(0..255).pack("C*")]
    end

    # Every octal escape between \000 and \377 should parse correctly.
    def test_all_escapes
      input = '[99.000] S "'
      input += '\000\001\002\003\004\005\006\007\010\011\012\013\014\015\016\017'
      input += '\020\021\022\023\024\025\026\027\030\031\032\033\034\035\036\037'
      input += '\040\041\042\043\044\045\046\047\050\051\052\053\054\055\056\057'
      input += '\060\061\062\063\064\065\066\067\070\071\072\073\074\075\076\077'
      input += '\100\101\102\103\104\105\106\107\110\111\112\113\114\115\116\117'
      input += '\120\121\122\123\124\125\126\127\130\131\132\133\134\135\136\137'
      input += '\140\141\142\143\144\145\146\147\150\151\152\153\154\155\156\157'
      input += '\160\161\162\163\164\165\166\167\170\171\172\173\174\175\176\177'
      input += '\200\201\202\203\204\205\206\207\210\211\212\213\214\215\216\217'
      input += '\220\221\222\223\224\225\226\227\230\231\232\233\234\235\236\237'
      input += '\240\241\242\243\244\245\246\247\250\251\252\253\254\255\256\257'
      input += '\260\261\262\263\264\265\266\267\270\271\272\273\274\275\276\277'
      input += '\300\301\302\303\304\305\306\307\310\311\312\313\314\315\316\317'
      input += '\320\321\322\323\324\325\326\327\330\331\332\333\334\335\336\337'
      input += '\340\341\342\343\344\345\346\347\350\351\352\353\354\355\356\357'
      input += '\360\361\362\363\364\365\366\367\370\371\372\373\374\375\376\377'
      input += "\"\n"
      reader = ScripTTY::Util::Transcript::Reader.new
      timestamp, type, args = reader.parse_line(input)
      assert_equal 99.0, timestamp
      assert_equal type, :from_server
      assert_equal args, [(0..255).pack("C*")]
    end
  end
end
