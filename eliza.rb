#!/usr/bin/env ruby

# This implementation of the Eliza chatterbot is inspired by 
# Charles Hayden's Java code at http://www.chayden.net/eliza/Eliza.html

class Script
	attr_accessor :debug_print

	def initialize(source)
		if source.kind_of? IO
			parse source
		else
			File.open(source, 'r') { |f| parse f }
		end
	end

	def repl(is = $stdin, os = $stdout)
		os.puts @initial.sample

		while true
			os.print "> "
			input = is.gets
			break unless input
			input.strip!
			next if input.empty?
			break if @quit.include? input
			os.puts transform(input)
		end

		os.puts @final.sample		
	end

	def print_script(os = $stdout)
		@initial.each       { |str|      os.puts "initial: #{str}"         }
		@final.each         { |str|      os.puts "final: #{str}"           }
		@quit.each          { |str|      os.puts "quit: #{str}"            }
		@pre.each           { |src,dest| os.puts "pre: #{src} #{dest}"     }
		@post.each          { |src,dest| os.puts "post: #{src} #{dest}"    }
		@synons.values.each { |arr|      os.puts "synon: #{arr.join(' ')}" }
		@keys.values.each   { |key|      key.print(os)                     }
	end

private
	class Key
		attr_reader :name, :rank, :decompositions

		def initialize(name, rank = 1)
			@name = name
			@rank = rank
			@decompositions = []
		end

		def print(os = $stdout)
			os.puts "key: #{@name} #{@rank}"
			@decompositions.each { |d| d.print(os) }
		end
	end

	class Decomp
		attr_reader :mem, :pattern, :reassemblies

		def initialize(mem, pattern)
			@mem = mem
			@pattern = pattern
			@reassemblies = []
			@current = 0
		end

		def next_reasmb
			reasmb = @reassemblies[@current]
			@current = (@current + 1) % @reassemblies.size
			reasmb
		end

		def print(os = $stdout)
			os.puts "  decomp: #{@mem ? '$ ' : ''}#{@pattern}"
			@reassemblies.each { |r| os.puts "    reasmb: #{r}" }
		end
	end

	def parse(f)
		@initial = []
		@final   = []
		@quit    = []
		@pre     = {}
		@post    = {}
		@synons  = {}
		@keys    = {}
		@memory  = []

		for line in f.readlines
			if /^initial: (.*)$/ =~ line
				@initial << $1
			elsif /^final: (.*)$/ =~ line
				@final << $1
			elsif /^quit: (.*)$/ =~ line
				@quit << $1
			elsif /^pre: (\S+) (.*)$/ =~ line
				@pre[$1] = $2
			elsif /^post: (\S+) (.*)$/ =~ line
				@post[$1] = $2
			elsif /^synon: (.*)$/ =~ line
				words = $1.split
				@synons[words[0]] = words
			elsif /^key: (\S+) (\d+)$/ =~ line
				last_key = Key.new($1, $2.to_i)
				@keys[$1] = last_key
			elsif /^key: (\S+)$/ =~ line
				last_key = Key.new($1)
				@keys[$1] = last_key
			elsif /^  decomp: (\$ )?(.+)$/ =~ line
				last_decomp = Decomp.new(!!$1, $2)
				last_key.decompositions << last_decomp
			elsif /^    reasmb: (.+)$/ =~ line
				last_decomp.reassemblies << $1
			end
		end

		check_script
	end

	def check_script()
		for key in @keys.values
			for decomp in key.decompositions
				if /@(\w+)/ =~ decomp.pattern
					raise "Can not find synonyms: #{$1}" unless @synons[$1]
				end
				for reasmb in decomp.reassemblies
					if /^goto (.*)$/ =~ reasmb
						raise "Can not find goto key: #{$1}" unless @keys[$1]
					end
				end
			end
		end
	end

	def replace(str, replacements)
		words = str.split
		words.map! { |word| replacements[word] || word }
		words.join(' ')
	end

	def transform(str)
		str.downcase!

		# preprocess input string
		str = replace(str, @pre)

		# convert punctuation to periods
		str.gsub!(/[?!,]/, '.')

		# do each sentence separately
		for sentence in str.split('.')
			$stderr.puts "trying to transform sentence: #{sentence}" if @debug_print

			if reply = transform_sentence(sentence)
				return reply
			end
		end

		# nothing matched, so try memory
		if reply = @memory.shift
			return reply
		end

		# no memory, reply with xnone
		if key = @keys['xnone']
			if reply = decompose(key, str)
				return reply if reply.kind_of? String
			end
		end

		"I am at a loss for words."
	end

	def transform_sentence(str)
		# find keywords sorted by rank in descending order
		keywords =
			str.split
			.map { |word| @keys[word] }
			.compact
			.sort { |a,b| b.rank <=> a.rank }

		for key in keywords
			while key.kind_of? Key
				result = decompose(key, str)
				return result if result.kind_of? String
				key = result
			end
		end

		nil
	end

	# decompose will either return a new key to follow, the reply as a string or nil
	def decompose(key, str)
		$stderr.puts "trying keyword: #{key.name}" if @debug_print

		for d in key.decompositions
			$stderr.puts "trying decomposition: #{d.pattern}" if @debug_print

			# build a regular expression
			regex_str = d.pattern.gsub(/(\s*)\*(\s*)/) do |m|
				s = ''
				s += '\b' if not $1.empty?
				s += '(.*)'
				s += '\b' if not $2.empty?
				s
			end
			# include all synonyms for words starting with @
			regex_str.gsub!(/@(\w+)/) do |m|
				"(#{@synons[$1].join('|')})"
			end

			$stderr.puts "decomposition regex: #{regex_str}" if @debug_print

			if m = /#{regex_str}/.match(str)
				return assemble(d, m)
			end
		end

		nil
	end

	def assemble(decomp, match)
		reasmb = decomp.next_reasmb
		$stderr.puts "using reassembly pattern: #{reasmb}" if @debug_print

		if /^goto (.*)$/ =~ reasmb
			return @keys[$1]
		end

		# assemble reply with help of decomposition matches and postprocessing
		reply = reasmb.gsub(/\((\d)\)/) { |m| replace(match[$1.to_i], @post) }
		$stderr.puts "reply after assembly: #{reply}" if @debug_print

		if decomp.mem
			$stderr.puts "save to memmory: #{reply}" if @debug_print
			@memory << reply
			return nil
		end

		reply
	end
end

# Patch the array class to add a 'sample' method if it doesn't exixts.
# It was added to Ruby in 1.9 and returns a random element.
if not [].respond_to? :sample
	class Array
		def sample
			self[rand(length)]
		end
	end
end

if __FILE__ == $0
	require 'optparse'

	debug_print = false
	script_source = DATA

	OptionParser.new do |opts|
		opts.on("-d", "--debug-print") do |b|
			debug_print = b
		end
		opts.on("-s", "--script PATH") do |path|
			script_source = path
		end
	end.parse!(ARGV)

	script = Script.new(script_source)
	script.debug_print = debug_print
	script.repl
end

__END__
initial: How do you do.  Please tell me your problem.
final: Goodbye.  Thank you for talking to me.
quit: bye
quit: goodbye
quit: quit
pre: dont don't
pre: cant can't
pre: wont won't
pre: recollect remember
pre: dreamt dreamed
pre: dreams dream
pre: maybe perhaps
pre: how what
pre: when what
pre: certainly yes
pre: machine computer
pre: computers computer
pre: were was
pre: you're you are
pre: i'm i am
pre: same alike
post: am are
post: your my
post: me you
post: myself yourself
post: yourself myself
post: i you
post: you I
post: my your
post: i'm you are
synon: belief feel think believe wish
synon: family mother mom father dad sister brother wife children child
synon: desire want need
synon: sad unhappy depressed sick
synon: happy elated glad better
synon: cannot can't
synon: everyone everybody nobody noone
synon: be am is are was
key: xnone
  decomp: *
    reasmb: I'm not sure I understand you fully.
    reasmb: Please go on.
    reasmb: What does that suggest to you ?
    reasmb: Do you feel strongly about discussing such things ?
key: sorry
  decomp: *
    reasmb: Please don't apologise.
    reasmb: Apologies are not necessary.
    reasmb: I've told you that apologies are not required.
key: apologise
  decomp: *
    reasmb: goto sorry
key: remember 5
  decomp: * i remember *
    reasmb: Do you often think of (2) ?
    reasmb: Does thinking of (2) bring anything else to mind ?
    reasmb: What else do you recollect ?
    reasmb: Why do you recollect (2) just now ?
    reasmb: What in the present situation reminds you of (2) ?
    reasmb: What is the connection between me and (2) ?
  decomp: * do you remember *
    reasmb: Did you think I would forget (2) ?
    reasmb: Why do you think I should recall (2) now ?
    reasmb: What about (2) ?
    reasmb: goto what
    reasmb: You mentioned (2) ?
key: if 3
  decomp: * if *
    reasmb: Do you think its likely that (2) ?
    reasmb: Do you wish that (2) ?
    reasmb: What do you know about (2) ?
    reasmb: Really, if (2) ?
key: dreamed 4
  decomp: * i dreamed *
    reasmb: Really, (2) ?
    reasmb: Have you ever fantasized (2) while you were awake ?
    reasmb: Have you ever dreamed (2) before ?
    reasmb: goto dream
key: dream 3
  decomp: *
    reasmb: What does that dream suggest to you ?
    reasmb: Do you dream often ?
    reasmb: What persons appear in your dreams ?
    reasmb: Do you believe that dreams have something to do with your problems ?
key: perhaps
  decomp: *
    reasmb: You don't seem quite certain.
    reasmb: Why the uncertain tone ?
    reasmb: Can't you be more positive ?
    reasmb: You aren't sure ?
    reasmb: Don't you know ?
key: name 15
  decomp: *
    reasmb: I am not interested in names.
    reasmb: I've told you before, I don't care about names -- please continue.
key: deutsch
  decomp: *
    reasmb: goto xforeign
    reasmb: I told you before, I don't understand German.
key: francais
  decomp: *
    reasmb: goto xforeign
    reasmb: I told you before, I don't understand French.
key: italiano
  decomp: *
    reasmb: goto xforeign
    reasmb: I told you before, I don't understand Italian.
key: espanol
  decomp: *
    reasmb: goto xforeign
    reasmb: I told you before, I don't understand Spanish.
key: xforeign
  decomp: *
    reasmb: I speak only English.
key: hello
  decomp: *
    reasmb: How do you do.  Please state your problem.
    reasmb: Hi.  What seems to be your problem ?
key: computer 50
  decomp: *
    reasmb: Do computers worry you ?
    reasmb: Why do you mention computers ?
    reasmb: What do you think machines have to do with your problem ?
    reasmb: Don't you think computers can help people ?
    reasmb: What about machines worrys you ?
    reasmb: What do you think about machines ?
key: am
  decomp: * am i *
    reasmb: Do you believe you are (2) ?
    reasmb: Would you want to be (2) ?
    reasmb: Do you wish I would tell you you are (2) ?
    reasmb: What would it mean if you were (2) ?
    reasmb: goto what
  decomp: *
    reasmb: Why do you say 'am' ?
    reasmb: I don't understand that.
key: are
  decomp: * are you *
    reasmb: Why are you interested in whether I am (2) or not ?
    reasmb: Would you prefer if I weren't (2) ?
    reasmb: Perhaps I am (2) in your fantasies.
    reasmb: Do you sometimes think I am (2) ?
    reasmb: goto what
  decomp: * are *
    reasmb: Did you think they might not be (2) ?
    reasmb: Would you like it if they were not (2) ?
    reasmb: What if they were not (2) ?
    reasmb: Possibly they are (2).
key: your
  decomp: * your *
    reasmb: Why are you concerned over my (2) ?
    reasmb: What about your own (2) ?
    reasmb: Are you worried about someone else's (2) ?
    reasmb: Really, my (2) ?
key: was 2
  decomp: * was i *
    reasmb: What if you were (2) ?
    reasmb: Do you think you were (2) ?
    reasmb: Were you (2) ?
    reasmb: What would it mean if you were (2) ?
    reasmb: What does (2) suggest to you ?
    reasmb: goto what
  decomp: * i was *
    reasmb: Were you really ?
    reasmb: Why do you tell me you were (2) now ?
    reasmb: Perhaps I already know you were (2).
  decomp: * was you *
    reasmb: Would you like to believe I was (2) ?
    reasmb: What suggests that I was (2) ?
    reasmb: What do you think ?
    reasmb: Perhaps I was (2).
    reasmb: What if I had been (2) ?
key: i
  decomp: * i @desire *
    reasmb: What would it mean to you if you got (3) ?
    reasmb: Why do you want (3) ?
    reasmb: Suppose you got (3) soon ?
    reasmb: What if you never got (3) ?
    reasmb: What would getting (3) mean to you ?
    reasmb: What does wanting (3) have to do with this discussion ?
  decomp: * i am* @sad *
    reasmb: I am sorry to hear that you are (3).
    reasmb: Do you think that coming here will help you not to be (3) ?
    reasmb: I'm sure it's not pleasant to be (3).
    reasmb: Can you explain what made you (3) ?
  decomp: * i am* @happy *
    reasmb: How have I helped you to be (3) ?
    reasmb: Has your treatment made you (3) ?
    reasmb: What makes you (3) just now ?
    reasmb: Can you explan why you are suddenly (3) ?
  decomp: * i was *
    reasmb: goto was
  decomp: * i @belief * i *
    reasmb: Do you really think so ?
    reasmb: But you are not sure you (3).
    reasmb: Do you really doubt you (3) ?
  decomp: * i* @belief *you *
    reasmb: goto you
  decomp: * i am *
    reasmb: Is it because you are (2) that you came to me ?
    reasmb: How long have you been (2) ?
    reasmb: Do you believe it is normal to be (2) ?
    reasmb: Do you enjoy being (2) ?
  decomp: * i @cannot *
    reasmb: How do you think that you can't (3) ?
    reasmb: Have you tried ?
    reasmb: Perhaps you could (3) now.
    reasmb: Do you really want to be able to (3) ?
  decomp: * i don't *
    reasmb: Don't you really (2) ?
    reasmb: Why don't you (2) ?
    reasmb: Do you wish to be able to (2) ?
    reasmb: Does that trouble you ?
  decomp: * do i feel *
    reasmb: Tell me more about such feelings.
    reasmb: Do you often feel (2) ?
    reasmb: Do you enjoy feeling (2) ?
    reasmb: Of what does feeling (2) remind you ?
  decomp: * i * you *
    reasmb: Perhaps in your fantasies we (2) each other.
    reasmb: Do you wish to (2) me ?
    reasmb: You seem to need to (2) me.
    reasmb: Do you (2) anyone else ?
  decomp: *
    reasmb: You say (1) ?
    reasmb: Can you elaborate on that ?
    reasmb: Do you say (1) for some special reason ?
    reasmb: That's quite interesting.
key: you
  decomp: * you remind me of *
    reasmb: goto alike
  decomp: * you are *
    reasmb: What makes you think I am (2) ?
    reasmb: Does it please you to believe I am (2) ?
    reasmb: Do you sometimes wish you were (2) ?
    reasmb: Perhaps you would like to be (2).
  decomp: * you* me *
    reasmb: Why do you think I (2) you ?
    reasmb: You like to think I (2) you -- don't you ?
    reasmb: What makes you think I (2) you ?
    reasmb: Really, I (2) you ?
    reasmb: Do you wish to believe I (2) you ?
    reasmb: Suppose I did (2) you -- what would that mean ?
    reasmb: Does someone else believe I (2) you ?
  decomp: * you *
    reasmb: We were discussing you -- not me.
    reasmb: Oh, I (2) ?
    reasmb: You're not really talking about me -- are you ?
    reasmb: What are your feelings now ?
key: yes
  decomp: *
    reasmb: You seem to be quite positive.
    reasmb: You are sure.
    reasmb: I see.
    reasmb: I understand.
key: no
  decomp: *
    reasmb: Are you saying no just to be negative?
    reasmb: You are being a bit negative.
    reasmb: Why not ?
    reasmb: Why 'no' ?
key: my 2
  decomp: $ * my *
    reasmb: Lets discuss further why your (2).
    reasmb: Earlier you said your (2).
    reasmb: But your (2).
    reasmb: Does that have anything to do with the fact that your (2) ?
  decomp: * my* @family *
    reasmb: Tell me more about your family.
    reasmb: Who else in your family (4) ?
    reasmb: Your (3) ?
    reasmb: What else comes to mind when you think of your (3) ?
  decomp: * my *
    reasmb: Your (2) ?
    reasmb: Why do you say your (2) ?
    reasmb: Does that suggest anything else which belongs to you ?
    reasmb: Is it important that your (2) ?
key: can
  decomp: * can you *
    reasmb: You believe I can (2) don't you ?
    reasmb: goto what
    reasmb: You want me to be able to (2).
    reasmb: Perhaps you would like to be able to (2) yourself.
  decomp: * can i *
    reasmb: Whether or not you can (2) depends on you more than me.
    reasmb: Do you want to be able to (2) ?
    reasmb: Perhaps you don't want to (2).
    reasmb: goto what
key: what
  decomp: *
    reasmb: Why do you ask ?
    reasmb: Does that question interest you ?
    reasmb: What is it you really wanted to know ?
    reasmb: Are such questions much on your mind ?
    reasmb: What answer would please you most ?
    reasmb: What do you think ?
    reasmb: What comes to mind when you ask that ?
    reasmb: Have you asked such questions before ?
    reasmb: Have you asked anyone else ?
key: because
  decomp: *
    reasmb: Is that the real reason ?
    reasmb: Don't any other reasons come to mind ?
    reasmb: Does that reason seem to explain anything else ?
    reasmb: What other reasons might there be ?
key: why
  decomp: * why don't you *
    reasmb: Do you believe I don't (2) ?
    reasmb: Perhaps I will (2) in good time.
    reasmb: Should you (2) yourself ?
    reasmb: You want me to (2) ?
    reasmb: goto what
  decomp: * why can't i *
    reasmb: Do you think you should be able to (2) ?
    reasmb: Do you want to be able to (2) ?
    reasmb: Do you believe this will help you to (2) ?
    reasmb: Have you any idea why you can't (2) ?
    reasmb: goto what
  decomp: *
    reasmb: goto what
key: everyone 2
  decomp: * @everyone *
    reasmb: Realy, (2) ?
    reasmb: Surely not (2).
    reasmb: Can you think of anyone in particular ?
    reasmb: Who, for example?
    reasmb: Are you thinking of a very special person ?
    reasmb: Who, may I ask ?
    reasmb: Someone special perhaps ?
    reasmb: You have a particular person in mind, don't you ?
    reasmb: Who do you think you're talking about ?
key: everybody 2
  decomp: *
    reasmb: goto everyone
key: nobody 2
  decomp: *
    reasmb: goto everyone
key: noone 2
  decomp: *
    reasmb: goto everyone
key: always 1
  decomp: *
    reasmb: Can you think of a specific example ?
    reasmb: When ?
    reasmb: What incident are you thinking of ?
    reasmb: Really, always ?
key: alike 10
  decomp: *
    reasmb: In what way ?
    reasmb: What resemblence do you see ?
    reasmb: What does that similarity suggest to you ?
    reasmb: What other connections do you see ?
    reasmb: What do you suppose that resemblence means ?
    reasmb: What is the connection, do you suppose ?
    reasmb: Could here really be some connection ?
    reasmb: How ?
key: like 10
  decomp: * @be *like *
    reasmb: goto alike
