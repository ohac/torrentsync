$ ->
  $('input').change ->
    hidegreen = $('#hidegreen').attr('checked')
    searchtext = $('#filter').val()
    $('#torrents .torrent').each ->
      torrent = $(this)
      hide = false
      if hidegreen
        peers = $('td', torrent)
        hide = hide or peers.hasClass('good') or peers.hasClass('great')
      if searchtext.length > 0
        hide = hide or $('a', torrent).text().indexOf(searchtext) < 0
      if hide
        torrent.hide()
      else
        torrent.show()
