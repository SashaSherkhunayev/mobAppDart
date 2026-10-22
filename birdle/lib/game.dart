/// Game logic and supporting types for Birdle,
/// a five-letter word-guessing game similar to Wordle.
///
/// Defines the [Game] state machine and the
/// [Word], [Letter], and [HitType] data model used to
/// represent guesses and their evaluation against a hidden word.
library;

import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

/// The result of evaluating a [Letter] of a guess against the hidden word.
enum HitType {
  /// The letter hasn't yet been evaluated.
  none,

  /// The letter matches the hidden word's letter at the same position.
  hit,

  /// The letter is in the hidden word, but at a different position.
  partial,

  /// The letter doesn't appear in the hidden word.
  miss,
}

/// A single character paired with its [HitType] against the hidden word.
typedef Letter = ({String char, HitType type});

/// Every word that can be legally entered as a guess.
const List<String> allLegalGuesses = [...legalWords, ...legalGuesses];

/// Words that can be chosen as the hidden word.
const List<String> legalWords = ['aback', 'abase', 'abate', 'abbey', 'abbot'];

/// Additional words accepted as guesses beyond those in [legalWords].
const List<String> legalGuesses = [
  'aback',
  'abase',
  'abate',
  'abbey',
  'abbot',
  'abhor',
  'abide',
  'abled',
  'abode',
  'abort',
];

/// A failure while fetching or parsing the Russian word list.
class RussianWordApiException implements Exception {
  const RussianWordApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

enum RussianWordValidation { noun, notFound, notNoun, numeral }

const String _wiktionaryApiHost = 'ru.wiktionary.org';

Future<Map<String, List<String>>> _loadRussianWordCategories(
  List<String> words,
) async {
  final response = await http
      .get(
        Uri.https(_wiktionaryApiHost, '/w/api.php', {
          'action': 'query',
          'prop': 'categories',
          'titles': words.join('|'),
          'cllimit': 'max',
          'format': 'json',
          'formatversion': '2',
          'origin': '*',
        }),
        headers: const {'User-Agent': 'Birdle/0.1 (Russian word game)'},
      )
      .timeout(const Duration(seconds: 15));

  if (response.statusCode != 200) {
    throw RussianWordApiException(
      'Проверка русских слов недоступна (HTTP ${response.statusCode}).',
    );
  }

  final decoded = jsonDecode(response.body);
  if (decoded is! Map<String, dynamic> ||
      decoded['query'] is! Map<String, dynamic>) {
    throw const RussianWordApiException(
      'Не удалось прочитать ответ словаря.',
    );
  }

  final pages = (decoded['query'] as Map<String, dynamic>)['pages'];
  if (pages is! List) {
    throw const RussianWordApiException(
      'В ответе словаря отсутствует список слов.',
    );
  }

  final categoriesByWord = <String, List<String>>{};
  for (final page in pages) {
    if (page is! Map<String, dynamic> || page['title'] is! String) continue;
    if (page.containsKey('missing')) continue;

    final categories = page['categories'];
    categoriesByWord[(page['title'] as String).toLowerCase()] = categories is List
        ? categories
              .whereType<Map<String, dynamic>>()
              .map((category) => category['title'])
              .whereType<String>()
              .toList()
        : const [];
  }

  return categoriesByWord;
}

bool _hasRussianNounCategory(Iterable<String> categories) {
  var hasNoun = false;
  var hasNumeral = false;

  for (final category in categories) {
    final title = category.replaceFirst('Категория:', '').toLowerCase();
    if (title.contains('числительн')) {
      hasNumeral = true;
    }
    if (title == 'русские существительные' ||
        title.startsWith('существительные ') && title.endsWith('/ru') ||
        title.startsWith('формы существительных/') && title.endsWith('/ru')) {
      hasNoun = true;
    }
  }

  return hasNoun && !hasNumeral;
}

RussianWordValidation _classifyRussianWord(
  List<String>? categories,
) {
  if (categories == null) return RussianWordValidation.notFound;
  if (categories.any((category) => category.toLowerCase().contains('числительн'))) {
    return RussianWordValidation.numeral;
  }
  return _hasRussianNounCategory(categories)
      ? RussianWordValidation.noun
      : RussianWordValidation.notNoun;
}

/// Game state of a single round of Birdle,
/// a five-letter word-guessing game similar to Wordle.
///
/// Exposes the state and methods a UI needs to
/// evaluate guesses and track progress,
/// but doesn't advance play on its own.
///
/// Clients drive each round by calling [guess] to submit any five-letter
/// attempt and [resetGame] to start over.
class Game {
  /// The default maximum number of guesses allowed in a [Game].
  static const int defaultMaxGuesses = 5;

  /// Creates a new game with [maxGuesses] guesses allowed.
  ///
  /// If [seed] is provided, the hidden word is
  /// chosen deterministically from [legalWords],
  /// otherwise it is selected at random.
  Game({
    this.maxGuesses = defaultMaxGuesses,
    this.seed,
    String? wordToGuess,
    List<String>? wordPool,
  }) : _wordToGuess = wordToGuess == null
           ? _generateInitialWord(seed)
           : Word.fromString(wordToGuess),
       _wordPool = wordPool,
      _guesses = List<Word>.filled(maxGuesses, Word.empty());

  /// Downloads the Russian word list and creates a game with a random
  /// five-letter Cyrillic word.
  static Future<Game> createRussian({
    int maxGuesses = Game.defaultMaxGuesses,
  }) async {
    final response = await http
        .get(
          Uri.parse(
            'https://raw.githubusercontent.com/hingston/russian/master/10000-russian-words-cyrillic-only.txt',
          ),
        )
        .timeout(const Duration(seconds: 15));

    if (response.statusCode != 200) {
      throw RussianWordApiException(
        'Словарь недоступен (HTTP ${response.statusCode}).',
      );
    }

    final russianWordPattern = RegExp(r'^[а-яё]{5}$');
    final russianFiveLetterWords = response.body
        .split(RegExp(r'\s+'))
        .map((word) => word.toLowerCase())
        .where(russianWordPattern.hasMatch)
        .toSet()
        .toList();

    if (russianFiveLetterWords.isEmpty) {
      throw const RussianWordApiException(
        'В загруженном словаре нет подходящих слов.',
      );
    }

    russianFiveLetterWords.shuffle();

    String? word;
    List<String>? russianNounWords;
    for (var start = 0; start < russianFiveLetterWords.length; start += 50) {
      final candidates = russianFiveLetterWords.skip(start).take(50).toList();
      final categoriesByWord = await _loadRussianWordCategories(candidates);
      final nouns = candidates
          .where(
            (candidate) => _hasRussianNounCategory(
              categoriesByWord[candidate] ?? const [],
            ),
          )
          .toList();

      if (nouns.isNotEmpty) {
        word = nouns[Random().nextInt(nouns.length)];
        russianNounWords = nouns;
        break;
      }
    }

    if (word == null) {
      throw const RussianWordApiException(
        'В словаре не нашлось пятибуквенных существительных.',
      );
    }

    return Game(
      maxGuesses: maxGuesses,
      wordToGuess: word,
      wordPool: russianNounWords,
    );
  }

  /// Whether [guess] is a Russian noun and is not a numeral.
  static Future<RussianWordValidation> validateRussianGuess(String guess) async {
    final normalizedGuess = guess.trim().toLowerCase();
    if (!RegExp(r'^[а-яё]{5}$').hasMatch(normalizedGuess)) {
      return RussianWordValidation.notFound;
    }

    final categoriesByWord = await _loadRussianWordCategories([
      normalizedGuess,
    ]);
    return _classifyRussianWord(categoriesByWord[normalizedGuess]);
  }

  /// The maximum number of guesses allowed in this game.
  final int maxGuesses;

  /// The seed used to choose the hidden word,
  /// or `null` if it was selected at random.
  final int? seed;

  /// The current hidden word, exposed publicly through [hiddenWord].
  Word _wordToGuess;

  final List<String>? _wordPool;

  /// Backing storage for [guesses].
  ///
  /// Holds every guess slot in order,
  /// with unfilled slots represented by empty [Word]s.
  List<Word> _guesses;

  /// The word the player is trying to guess.
  Word get hiddenWord => _wordToGuess;

  /// An unmodifiable view of every guess slot, including those still empty.
  UnmodifiableListView<Word> get guesses => UnmodifiableListView(_guesses);

  /// The most recently submitted guess,
  /// or an empty [Word] if no guesses have been made.
  Word get previousGuess {
    final index = _guesses.lastIndexWhere((word) => word.isNotEmpty);
    return index == -1 ? Word.empty() : _guesses[index];
  }

  /// The index of the next empty guess slot, or `-1` if every slot is full.
  int get activeIndex => _guesses.indexWhere((word) => word.isEmpty);

  /// The number of guesses still available to the player.
  int get guessesRemaining {
    if (activeIndex == -1) return 0;
    return maxGuesses - activeIndex;
  }

  /// Whether the most recent guess matches the hidden word.
  bool get didWin {
    if (_guesses.first.isEmpty) return false;

    for (final letter in previousGuess) {
      if (letter.type != HitType.hit) return false;
    }

    return true;
  }

  /// Whether all allowed guesses have been used without winning.
  bool get didLose => guessesRemaining == 0 && !didWin;

  /// Picks a new hidden word and clears every submitted guess.
  void resetGame() {
    final wordPool = _wordPool;
    _wordToGuess = wordPool == null
        ? _generateInitialWord(seed)
        : Word.fromString(
            wordPool[Random().nextInt(wordPool.length)],
          );
    _guesses = List<Word>.filled(maxGuesses, Word.empty());
  }

  /// Evaluates [guess] against the hidden word,
  /// records the result in [guesses], and returns it.
  ///
  /// Any five-letter word can be submitted; it does not have to be in
  /// [allLegalGuesses]. Use [matchGuessOnly] to evaluate without recording it.
  Word guess(String guess) {
    if (didWin) {
      throw StateError('The game has already been won.');
    }

    final result = matchGuessOnly(guess);
    addGuessToList(result);
    return result;
  }

  /// Whether [guess] is in the optional predefined list of guesses.
  ///
  /// The game accepts any five-letter word, regardless of this result.
  bool isLegalGuess(String guess) => Word.fromString(guess).isLegalGuess;

  /// Evaluates [guess] against the hidden word without advancing the game.
  Word matchGuessOnly(String guess) =>
      Word.fromString(guess).evaluateGuess(_wordToGuess);

  /// Stores [guess] in the next empty slot of [guesses].
  void addGuessToList(Word guess) {
    final guessIndex = activeIndex;
    if (guessIndex == -1) {
      throw StateError('No guesses remaining.');
    }

    _guesses[guessIndex] = guess;
  }

  /// Returns the starting hidden word for a new round.
  ///
  /// Picks a deterministic word from [legalWords] when [seed] is provided,
  /// or one at random otherwise.
  static Word _generateInitialWord(int? seed) =>
      seed == null ? Word.random() : Word.fromSeed(seed);
}

/// A five-letter word made up of [Letter]s, each tracking its [HitType].
class Word with IterableMixin<Letter> {
  /// Creates a word backed by the specified list of [Letter]s.
  Word(this._letters);

  /// Creates a word with five blank letters of [HitType.none].
  factory Word.empty() =>
      Word(List<Letter>.filled(5, (char: '', type: HitType.none)));

  /// Creates a [Word] from [guess].
  ///
  /// Each character is lowercased,
  /// every [Letter] starts as [HitType.none].
  factory Word.fromString(String guess) {
    if (guess.length != 5) {
      throw ArgumentError.value(
        guess,
        'guess',
        'Must be exactly 5 characters long.',
      );
    }

    final letters = guess
        .toLowerCase()
        .split('')
        .map((char) => (char: char, type: HitType.none))
        .toList();
    return Word(letters);
  }

  /// Creates a word chosen at random from [legalWords].
  factory Word.random() {
    final random = Random();
    final nextWord = legalWords[random.nextInt(legalWords.length)];
    return Word.fromString(nextWord);
  }

  /// Creates a word chosen from [legalWords] using [seed] as an index.
  factory Word.fromSeed(int seed) =>
      Word.fromString(legalWords[seed % legalWords.length]);

  /// An unmodifiable list of [Letter]s that make up this word.
  final List<Letter> _letters;

  @override
  Iterator<Letter> get iterator => _letters.iterator;

  /// Whether every [Letter] in this word has no character.
  @override
  bool get isEmpty => every((letter) => letter.char.isEmpty);

  @override
  int get length => _letters.length;

  /// The [Letter] at index [i] in word.
  Letter operator [](int i) => _letters[i];

  @override
  String toString() => _letters.map((letter) => letter.char).join().trim();

  /// Returns a multi-line string showing each [Letter] alongside its [HitType].
  ///
  /// Used to play the game from the command line.
  String toStringVerbose() => _letters
      .map((letter) => '${letter.char} - ${letter.type.name}')
      .join('\n');
}

/// Validation and guess-evaluation logic on [Word].
extension WordUtils on Word {
  /// Whether this word appears in [allLegalGuesses].
  bool get isLegalGuess => allLegalGuesses.contains(toString());

  /// Compares this [Word] against the specified [hiddenWord]
  /// and returns a new [Word] with the same letters,
  /// but where each [Letter] has new a [HitType] of
  /// [HitType.hit], [HitType.partial], or [HitType.miss].
  Word evaluateGuess(Word hiddenWord) {
    final result = List<Letter>.filled(length, (char: '', type: HitType.none));
    // Counts hidden-word letters that can still be claimed as partial matches.
    final unmatchedHiddenLetterCounts = <String, int>{};

    // Reserve exact matches before scoring partial matches.
    for (var i = 0; i < length; i++) {
      final guessChar = this[i].char;
      final hiddenChar = hiddenWord[i].char;

      if (guessChar == hiddenChar) {
        result[i] = (char: guessChar, type: HitType.hit);
      } else {
        // Track non-hit hidden letters for the partial-match pass.
        final unmatchedCount = unmatchedHiddenLetterCounts[hiddenChar] ?? 0;
        unmatchedHiddenLetterCounts[hiddenChar] = unmatchedCount + 1;
      }
    }

    // Spend each remaining hidden letter only once for partial matches.
    for (var i = 0; i < length; i++) {
      if (result[i].type == HitType.hit) continue;

      final guessChar = this[i].char;
      final unmatchedCount = unmatchedHiddenLetterCounts[guessChar] ?? 0;
      final isPartial = unmatchedCount > 0;
      if (isPartial) {
        // Use one available hidden letter for this partial match.
        unmatchedHiddenLetterCounts[guessChar] = unmatchedCount - 1;
      }

      result[i] = (
        char: guessChar,
        type: isPartial ? HitType.partial : HitType.miss,
      );
    }

    return Word(result);
  }
}
