package haxetoml;

using hx.strings.StringBuilder;
using hx.strings.Strings;

private enum TokenType {
  TkInvalid;
  TkComment;
  TkKey;
  TkTable;
  TkInlineTableStart;
  TkInlineTableEnd;
  TkTableArray;
  TkString;
  TkInteger;
  TkFloat;
  TkBoolean;
  TkDatetime;
  TkAssignment;
  TkComma;
  TkBBegin;
  TkBEnd;
}

private typedef Token = {
  var type: TokenType;
  var value: String;
  var lineNum: Int;
  var colNum: Int;
}

class TomlParser {
  var tokens: Array<Token>;
  var root: Dynamic;
  var pos = 0;

  public var currentToken(get, null): Token;

  /**
   * Set up a new TomlParser instance
   */
  public function new() {}

  /**
   * Parse a TOML string into a dynamic object. Throws a String containing an error message if an error is encountered.
   */
  public function parse(str: String, ?defaultValue: Dynamic): Dynamic {
    tokens = tokenize(str);
    if (defaultValue != null) {
      root = defaultValue;
    } else {
      root ={};
    }
    pos = 0;

    parseObj();

    return root;
  }

  function get_currentToken() {
    return tokens[pos];
  }

  function nextToken() {
    pos++;
  }

  function parseObj() {
    var table = '';

    while (pos < tokens.length) {
      switch (currentToken.type) {
        case TkTableArray:
          table = decodeTableArray(currentToken);
          createTable(table, true);
          nextToken();

        case TkTable:
          table = decodeTable(currentToken);
          createTable(table, false);
          nextToken();
        case TkKey:
          // Dotted key.
          if (currentToken.value.indexOf('.') != -1) {
            table = parseDottedKey();
          } else {
            final pair = parsePair();
            setPair(table, pair);
          }
        default:
          InvalidToken(currentToken);
      }
    }
  }

  function parseDottedKey(): String {
    createTable(currentToken.value, false);
    final table = currentToken.value;
    nextToken();
    nextToken();
    final v = parseValue();
    final lastDotPos = table.lastIndexOf('.');
    var tablePart = table.substring(0, lastDotPos);
    var keyPart = table.substring(lastDotPos + 1);
    setPair(tablePart, { key: keyPart, value: v });

    return table;
  }

  function parsePair() {
    var key = '';
    var value ={};

    if (currentToken.type == TkKey) {
      key = decodeKey(currentToken);
      nextToken();

      if (currentToken.type == TkAssignment) {
        nextToken();
        value = parseValue();
      } else {
        InvalidToken(currentToken);
      }
    } else if (currentToken.type == TkAssignment) {
      nextToken();
      value = parseValue();
    } else {
      InvalidToken(currentToken);
    }

    return { key: key, value: value };
  }

  function parseValue(): Dynamic {
    var value: Dynamic ={};
    switch (currentToken.type) {
      case TkString:
        value = decodeString(currentToken);
        nextToken();
      case TkDatetime:
        value = decodeDatetime(currentToken);
        nextToken();
      case TkFloat:
        value = decodeFloat(currentToken);
        nextToken();
      case TkInteger:
        value = decodeInteger(currentToken);
        nextToken();
      case TkBoolean:
        value = decodeBoolean(currentToken);
        nextToken();
      case TkBBegin:
        value = parseArray();
      case TkInlineTableStart:
        value = parseInlineTable();
      default:
        InvalidToken(currentToken);
    };

    return value;
  }

  function parseArray(): Array<Dynamic> {
    final array = [];

    if (currentToken.type == TkBBegin) {
      nextToken();
      while (true) {
        if (currentToken.type != TkBEnd) {
          array.push(parseValue());
        } else {
          nextToken();
          break;
        }

        switch (currentToken.type) {
          case TkComma:
            nextToken();
          case TkBEnd:
            nextToken();
            break;
          default:
            InvalidToken(currentToken);
        }
      }
    }

    return array;
  }

  function parseInlineTable(): Dynamic {
    var table: Dynamic ={};
    if (currentToken.type == TkInlineTableStart) {
      nextToken();
      while (true) {
        if (currentToken.type != TkInlineTableEnd) {
          final pair = parsePair();
          final keys = pair.key.split('.');

          if (keys.length > 1) {
            var obj = table;
            for (i in 0...keys.length) {
              var key = keys[i];
              if (key != '' && i < keys.length - 1) {
                var next = Reflect.field(obj, key);
                if (next == null) {
                  Reflect.setField(obj, key, {});
                  next = Reflect.field(obj, key);
                }
                obj = next;
              }
            }
            Reflect.setField(obj, keys[keys.length - 1], pair.value);
          } else {
            Reflect.setField(table, pair.key, pair.value);
          }
        }

        switch (currentToken.type) {
          case TkComma:
            nextToken();
          case TkInlineTableEnd:
            nextToken();
            break;
          default:
            InvalidToken(currentToken);
        }
      }
    }

    return table;
  }

  function createTable(table: String, tableArray: Bool) {
    final keys = table.split('.');
    var obj: Dynamic = root;

    for (i in 0...keys.length) {
      final key = keys[i];
      var next = Reflect.field(obj, key);
      if (next == null) {
        if (tableArray) {
          var next: Dynamic ={};
          Reflect.setField(obj, key, [next]);
        } else {
          Reflect.setField(obj, key, {});
          next = Reflect.field(obj, key);
        }
      } else if (i == keys.length - 1 && tableArray) {
        if (next is Array) {
          final nextArray: Array<Dynamic> = next;
          final nextItem: Dynamic ={};
          nextArray.push(nextItem);
          next = nextItem;
        }
      } else {
        if (next is Array) {
          next = cast next[next.length - 1];
        }
      }
      obj = next;
    }
  }

  function setPair(table: String, pair: { key: String, value: Dynamic }) {
    final keys = table.split('.');
    var obj: Dynamic = root;
    for (key in keys) {
      // A Haxe glitch: empty string will be parsed to ['']
      if (key != '') {
        obj = Reflect.field(obj, key);
        if (obj is Array) {
          var ar: Array<Dynamic> = cast obj;
          obj = cast ar[ar.length - 1];
        }
      }
    }

    Reflect.setField(obj, pair.key, pair.value);
  }

  function decode<T>(token: Token, expectedType: TokenType, decoder: String->T): T {
    if (token.type == expectedType)
      return decoder(token.value);
    else
      throw('Can\'t parse ${token.type} as $expectedType');
  }

  function decodeTable(token: Token): String {
    return decode(token, TkTable, function(v) {
      return v.substring(1, v.length - 1);
    });
  }

  function decodeTableArray(token: Token): String {
    return decode(token, TkTableArray, function(v) {
      return v.substring(2, v.length - 2);
    });
  }

  function decodeString(token: Token): String {
    return decode(token, TkString, function(v) {
      try {
        return unescape(v);
      } catch (msg:String) {
        InvalidToken(token);
        return "";
      };
    });
  }

  function decodeDatetime(token: Token): Date {
    return decode(token, TkDatetime, function(v) {
      final dateStr = ~/(T|Z)/.replace(v, '');
      return Date.fromString(dateStr);
    });
  }

  function decodeFloat(token: Token): Float {
    return decode(token, TkFloat, function(v) {
      return Std.parseFloat(v);
    });
  }

  function decodeInteger(token: Token): Int {
    return decode(token, TkInteger, function(v) {
      return Std.parseInt(v);
    });
  }

  function decodeBoolean(token: Token): Bool {
    return decode(token, TkBoolean, function(v) {
      return v == "true";
    });
  }

  function decodeKey(token: Token): String {
    return decode(token, TkKey, function(v) {
      return v;
    });
  }

  function unescape(str: String) {
    var pos = 0;
    final sb = new StringBuilder();

    final len = str.length8();
    while (pos < len) {
      var c = str.charCodeAt8(pos);
      // strip first and last quotation marks
      if ((pos == 0 || pos == len - 1) && c == '"'.code) {
        pos++;
        continue;
      }

      pos++;

      if (c == '\\'.code) {
        c = str.charCodeAt8(pos);
        pos++;

        switch (c) {
          case 'r'.code:
            sb.addChar('\r'.code);
          case 'n'.code:
            sb.addChar('\n'.code);
          case 't'.code:
            sb.addChar('\t'.code);
          case 'b'.code:
            sb.addChar(8);
          case 'f'.code:
            sb.addChar(12);
          case '/'.code, '\\'.code, '\''.code:
            sb.addChar(c);
          case 'u'.code:
            final uc = Std.parseInt('0x${str.substr8(pos, 4)}');
            sb.addChar(uc);
            pos += 4;
          case 'U'.code:
            final uc = Std.parseInt('0x${str.substr8(pos, 8)}');
            sb.addChar(uc);
            pos += 8;
          case '"'.code:
            sb.addChar('\"'.code);
          default:
            throw('Invalid Escape');
        }
      } else {
        sb.addChar(c);
      }
    }

    return sb.toString();
  }

  function tokenize(str: String) {
    final tokens = new Array<Token>();
    final lineBreakPattern = ~/\r\n?|\n/g;
    final lines = lineBreakPattern.split(str);
    final patterns = [
      { type: TkComment, ereg: ~/^#.*$/ },
      { type: TkTable, ereg: ~/^\[([^\[].*?)\]/ },
      { type: TkTableArray, ereg: ~/^\[{2}([^\[].*?)\]{2}/ },
      { type: TkInlineTableStart, ereg: ~/^\{/ },
      { type: TkInlineTableEnd, ereg: ~/^\}/ },
      { type: TkString, ereg: ~/^"((\\")|[^"])*"/ },
      { type: TkAssignment, ereg: ~/^=/ },
      { type: TkBBegin, ereg: ~/^\[/ },
      { type: TkBEnd, ereg: ~/^\]/ },
      { type: TkComma, ereg: ~/^,/ },
      { type: TkKey, ereg: ~/^\S+/ },
      { type: TkDatetime, ereg: ~/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/ },
      { type: TkFloat, ereg: ~/^-?\d+\.\d+/ },
      { type: TkInteger, ereg: ~/^-?\d+/ },
      { type: TkBoolean, ereg: ~/^true|^false/ },
    ];

    for (lineNum in 0...lines.length) {
      final line = lines[lineNum];

      var colNum = 0;
      var tokenColNum = 0;
      var inInlineTable = false;
      var canBeKey = false;
      while (colNum < line.length) {
        while (StringTools.isSpace(line, colNum)) {
          colNum++;
        }

        if (colNum >= line.length) {
          break;
        }

        final subline = line.substring(colNum);
        var matched = false;
        for (pattern in patterns) {
          final type = pattern.type;
          final ereg = pattern.ereg;

          if (ereg.match(subline)) {
            // TkKey has to be the first token of a line
            if ((type == TkTable || type == TkTableArray || type == TkKey)
              && tokenColNum != 0
              && (type != TkKey || !inInlineTable || !canBeKey)) {
              continue;
            }

            if (type != TkComment) {
              tokens.push({
                type: type,
                value: ereg.matched(0),
                lineNum: lineNum,
                colNum: colNum,
              });
              tokenColNum++;
            }
            colNum += ereg.matchedPos().len;
            matched = true;

            if (type == TkInlineTableStart) {
              inInlineTable = true;
              canBeKey = true;
            } else if (type == TkInlineTableEnd) {
              inInlineTable = false;
            }

            if (inInlineTable) {
              if (type == TkKey) {
                canBeKey = false;
              } else if (type == TkComma) {
                canBeKey = true;
              }
            }

            break;
          }
        }
        if (!matched) {
          InvalidCharacter(line.charAt(colNum), lineNum, colNum);
        }
      }
    }

    return tokens;
  }

  function InvalidCharacter(char: String, lineNum: Int, colNum: Int) {
    throw('Line $lineNum Character ${colNum + 1}: Invalid Character \'$char\', Character Code ${char.charCodeAt(0)}');
  }

  function InvalidToken(token: Token) {
    throw('Line ${token.lineNum + 1} Character ${token.colNum + 1}: Invalid Token \'${token.value}\'(${token.type})');
  }

  /**
   * Static shortcut method to parse toml String into Dynamic object.
   */
  public static function parseString(toml: String, defaultValue: Dynamic) {
    return (new TomlParser()).parse(toml, defaultValue);
  }

  #if (neko || php || cpp)
  /**
   * Static shortcut method to read toml file and parse into Dynamic object.  Available on Neko, PHP and CPP.
   */
  public static function parseFile(filename: String, ?defaultValue: Dynamic) {
    return parseString(sys.io.File.getContent(filename), defaultValue);
  }
  #end
}
