"""Returned native passages and citation binding; expected facts use original CHM."""
from pathlib import Path
import copy
import json
import unittest
from evaluate_workflows import native_documentation_passages, relevant_array_documentation


class NativeDocumentation(unittest.TestCase):
    def setUp(self):
        fixture=json.loads((Path(__file__).with_name('fixtures')/'evaluation/cli-0.162.1-native-array-read.json').read_text(encoding='utf-8'))
        self.event=fixture['event'];self.item=self.event['item'];self.result=self.item['result'];self.root=self.result['structured_content']
        self.assertNotIn('text',self.root)
    def relevant(self):return relevant_array_documentation([self.event])
    def test_genuine_variables_read_matches_independent_indexing_facts(self):
        self.assertTrue(self.relevant())
        self.assertIn('Numbering of array elements starts with 0',self.result['content'][0]['text'])
        self.assertIn('program will be stopped',self.result['content'][0]['text'])
    def test_metadata_or_self_report_without_returned_passage_fails(self):
        for content in (None,[],[{'type':'text','text':'The model claims array indexing is zero based.'}],[{'type':'image','data':'anything'}]):
            with self.subTest(content=content):self.result['content']=content;self.assertFalse(self.relevant())
    def test_wrong_footer_citation_and_root_identity_fail(self):
        original=copy.deepcopy(self.event)
        for key in ('source_revision','corpus_revision','index_revision','topic_id','title','section_id'):
            with self.subTest(key=key):
                self.event=copy.deepcopy(original);self.event['item']['result']['structured_content']['citation'][key]='wrong';self.assertFalse(self.relevant())
        self.event=copy.deepcopy(original);self.event['item']['result']['structured_content']['section_id']='wrong';self.assertFalse(self.relevant())
    def test_error_response_and_image_only_continuation_fail(self):
        self.result['isError']=True;self.assertFalse(self.relevant());self.result.pop('isError')
        self.root['image_continuation']=True;self.assertFalse(self.relevant())
    def test_native_read_bounds_and_malformed_focus_fail(self):
        original=self.root['returned_chars']
        for count in (True,0,8001,'2409',None):
            with self.subTest(count=count):self.root['returned_chars']=count;self.assertFalse(self.relevant())
        self.root['returned_chars']=original;self.root['focus_match']=[];self.assertFalse(self.relevant())
    def test_focus_notices_are_bound_to_metadata(self):
        original=self.result['content'][0]['text']
        for kind,notice in [('none','No match for the requested focus. Showing the selected documentation.\n\n'),('approximate','Approximate focus match. Verify the requested identifier in the passage.\n\n')]:
            self.root['focus_match']=kind;self.result['content'][0]['text']=notice+original;self.assertTrue(self.relevant())
            self.result['content'][0]['text']=original;self.assertFalse(self.relevant())
    def test_supplementary_unicode_uses_native_utf16_counts(self):
        self.result['content'][0]['text']='😀'+self.result['content'][0]['text'];self.root['returned_chars']+=2
        self.assertTrue(self.relevant());self.root['returned_chars']-=1;self.assertFalse(self.relevant())
    def test_native_search_pairs_each_snippet_with_its_own_metadata(self):
        citation=copy.deepcopy(self.root['citation'])
        entry={'title':citation['title'],'topic_id':citation['topic_id'],'source_revision':citation['source_revision'],'citation':citation,'signature':'','match_kind':'text'}
        search={'corpus_revision':self.root['corpus_revision'],'index_sha256':self.root['index_sha256'],'results':[entry]}
        footer='Source: '+citation['source_file']+' | '+citation['title']+' | '+citation['section_id']+' | source '+citation['source_revision'][:12]
        # Facts checked in original variables.htm; no structured snippet exists.
        text='1. Variables [text]\nNumbering of array elements starts with 0. The last element has an index that is 1 less than the array size. A dimension is indexed from 0 to the dimension size-1.\n'+footer
        event={'type':'item.completed','item':{'type':'mcp_tool_call','server':'mql5-chm','tool':'mql5_chm_search','status':'completed','result':{'structured_content':search,'content':[{'type':'text','text':text}]}}}
        self.assertTrue(relevant_array_documentation([event]))
        event['item']['result']['content'][0]['text']=text.replace(footer,'Source: another topic');self.assertFalse(relevant_array_documentation([event]))
    def test_search_cannot_borrow_a_different_results_passage(self):
        source=copy.deepcopy(self.root);source['signature']='';source['match_kind']='text'
        second=copy.deepcopy(source);second['topic_id']='mql5:'+'a'*24;second['title']='Unrelated';second['citation']['topic_id']=second['topic_id'];second['citation']['title']='Unrelated';second['citation']['section_id']=None
        root={'results':[source,second],'corpus_revision':source['corpus_revision'],'index_sha256':source['index_sha256']}
        first_footer='Source: mql5.chm | Variables | '+source['section_id']+' | source '+source['source_revision'][:12]
        second_footer='Source: mql5.chm | Unrelated | '+second['topic_id']+' | source '+second['source_revision'][:12]
        text='1. Variables [text]\nUnrelated statement.\n'+second_footer+'\n\n2. Unrelated [text]\nArrays are indexed from 0 to dimension_size-1.\n'+first_footer
        self.assertEqual(native_documentation_passages('mql5_chm_search',{'content':[{'type':'text','text':text}]},root),[])


if __name__=='__main__':unittest.main()
