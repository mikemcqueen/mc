I want some help designing the technology stack for a mobile classifier tool.

I have lists of word-pairs, and I need to manually classify them as "good" or not. I want a tool that will run on my iPhone, and when connected to bluetooth speakers, read off one of the pairs every couple of seconds (text to speech), and listen for a "yes", or "good" via the mic.  Keep a list of all the "yes/good" classified word-pairs for later extraction/processing.

One piece of the stack that I have already, that is optional to use, but it's working, is that I have the word-pair lists uploaded as Evernote notes, with a checkbox next to each word-pair.  And I have a tool for downloading an Evernote note and only saving the items that are "checked". So, one possible solution to the "save the yes/good pairs" is to integrate with Evernote and "check the boxes" via API or whatever, when a yes/good indicator is received.

Otherwise, the word-pairs are just lines in textfiles.

I'm probably going to want to support commands like "stop", "continue", "repeat", "back", "faster", "slower", as well.

I have no idea about the complexity/difficulty of integrating with bluetooth/audio/input/TTS.  That's the later that is is the most opaque to me, and i'm open to use a 3rd party library/utility if you think it makes sense.  Let me know if you have any questions.
