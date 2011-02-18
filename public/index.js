(function(){
  $(function() {
    return $('input').change(function() {
      var hidegreen, searchtext;
      hidegreen = $('#hidegreen').attr('checked');
      searchtext = $('#filter').val();
      return $('#torrents .torrent').each(function() {
        var hide, peers, torrent;
        torrent = $(this);
        hide = false;
        if (hidegreen) {
          peers = $('td', torrent);
          hide = hide || peers.hasClass('good') || peers.hasClass('great');
        }
        searchtext.length > 0 ? (hide = hide || $('a', torrent).text().indexOf(searchtext) < 0) : null;
        if (hide) {
          return torrent.hide();
        } else {
          return torrent.show();
        }
      });
    });
  });
})();
